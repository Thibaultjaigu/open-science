param(
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [switch]$SkipNode,
    [switch]$SkipPowerShell
)

# Run with PowerShell 7, Python 3, Git and VS 2022 C++ Build Tools available.
# A short, dedicated BuildRoot avoids MAX_PATH failures in Node's source generator.
$ErrorActionPreference = 'Stop'
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if ($BuildRoot.Length -gt 75) { throw 'Use a dedicated build directory with an absolute path shorter than 76 characters.' }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'The pinned runtime build currently supports Windows x64 only.' }
$sources = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sources.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$stage = Join-Path $PSScriptRoot 'x64'
New-Item -ItemType Directory -Force -Path $stage | Out-Null
# An interrupted build must not be mistaken for a completed runtime.
$marker = Join-Path $stage 'build.json'
if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }

function Get-Source($source, [string]$name) {
    $archive = Join-Path $BuildRoot $name
    if (!(Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $source.url -OutFile $archive }
    $algorithm = if ($source.sha512) { 'SHA512' } else { 'SHA256' }
    $expected = if ($source.sha512) { $source.sha512 } else { $source.sha256 }
    if ((Get-FileHash -LiteralPath $archive -Algorithm $algorithm).Hash -ne $expected) {
        throw "Source checksum mismatch: $name"
    }
    return $archive
}

function Apply-Patch([string]$source, [string]$patch) {
    Push-Location $source
    try {
        & git apply --check --ignore-whitespace $patch 2>$null
        if ($LASTEXITCODE -eq 0) {
            & git apply --ignore-whitespace $patch
            if ($LASTEXITCODE -ne 0) { throw "Cannot apply $patch" }
        } else {
            & git apply --reverse --check --ignore-whitespace $patch
            if ($LASTEXITCODE -ne 0) { throw "Unexpected source state: $patch" }
        }
    } finally { Pop-Location }
}

if (!$SkipNode) {
    $archive = Get-Source $sources.node 'node.tar.xz'
    $source = Join-Path $BuildRoot "node-v$($sources.node.version)"
    if (!(Test-Path -LiteralPath $source)) {
        & tar -xf $archive -C $BuildRoot
        if ($LASTEXITCODE -ne 0) { throw 'Node source extraction failed' }
    }
    Apply-Patch $source (Join-Path $PSScriptRoot 'node-appcontainer.patch')
    Push-Location $source
    try {
        $env:msbuild_args = '/m:1 /p:MultiProcMaxCount=2 /p:MultiProcessorCompilation=false /p:CL_MPCount=1'
        & .\vcbuild.bat x64 vs2022 no-cctest openssl-no-asm
        if ($LASTEXITCODE -ne 0) { throw 'Node build failed' }
    } finally { Pop-Location }
    $node = Join-Path $stage 'node'
    New-Item -ItemType Directory -Force -Path (Join-Path $node 'node_modules') | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'Release/node.exe') -Destination $node
    Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination (Join-Path $node 'LICENSE.node')
    Copy-Item -LiteralPath (Join-Path $source 'deps/npm') -Destination (Join-Path $node 'node_modules') -Recurse -Force
    foreach ($shim in @('npm', 'npm.cmd', 'npm.ps1', 'npx', 'npx.cmd', 'npx.ps1')) {
        Copy-Item -LiteralPath (Join-Path $source "deps/npm/bin/$shim") -Destination $node -Force
    }
}

if (!$SkipPowerShell) {
    $archive = Get-Source $sources.powershell 'powershell.tar.gz'
    $source = Join-Path $BuildRoot "PowerShell-$($sources.powershell.version)"
    if (!(Test-Path -LiteralPath $source)) {
        & tar -xf $archive -C $BuildRoot
        if ($LASTEXITCODE -ne 0) { throw 'PowerShell source extraction failed' }
    }
    Apply-Patch $source (Join-Path $PSScriptRoot 'powershell-appcontainer.patch')
    $sdkArchive = Get-Source $sources.dotnet 'dotnet.zip'
    $sdk = Join-Path $BuildRoot 'dotnet'
    if (!(Test-Path -LiteralPath (Join-Path $sdk 'dotnet.exe'))) {
        Expand-Archive -LiteralPath $sdkArchive -DestinationPath $sdk
    }
    $env:DOTNET_CLI_HOME = $BuildRoot
    $env:NUGET_PACKAGES = Join-Path $BuildRoot 'nuget'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    $env:PATH = "$sdk;$env:PATH"
    Push-Location $source
    try {
        Import-Module ./build.psm1
        Start-PSBuild -Configuration Release -Runtime win7-x64 -ReleaseTag "v$($sources.powershell.version)" -NoPSModuleRestore -Output (Join-Path $stage 'powershell')
    } finally { Pop-Location }
}

foreach ($file in @('node/node.exe', 'node/node_modules/npm/bin/npm-cli.js', 'powershell/pwsh.exe')) {
    if (!(Test-Path -LiteralPath (Join-Path $stage $file))) { throw "Runtime incomplete: $file" }
}
@{ node = $sources.node.version; powershell = $sources.powershell.version;
    patches = @('libuv-f46e4246b5277fe1c5888b88b24d8b78020dd4f8', 'powershell-appcontainer-v1')
} | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding utf8
