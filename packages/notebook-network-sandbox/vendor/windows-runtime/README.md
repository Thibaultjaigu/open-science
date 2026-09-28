# Windows Notebook runtime

AppContainer remains the execution boundary. It requires two runtime repairs:

- Node 22.23.3: backport only `deps/uv/src/win/pipe.c` from
  [libuv f46e424](https://github.com/libuv/libuv/commit/f46e4246b5277fe1c5888b88b24d8b78020dd4f8).
  AppContainer child stdio pipes must use the `LOCAL` namespace. The previous
  libuv implementation can block synchronously before the child timeout starts.
- PowerShell 7.6.5: skip inaccessible mapped drives when initializing providers,
  and preserve inaccessible ancestor components during path normalization while
  still validating the final item. Windows permits access to a granted descendant
  without granting metadata access to every ancestor. Neither change grants ACLs.

`sources.json` pins upstream source and portable SDK archive checksums. The two
patches are the complete runtime source delta. Build using PowerShell 7, Python 3,
Git, and Visual Studio 2022 C++ Build Tools:

```powershell
pwsh -File packages/notebook-network-sandbox/vendor/windows-runtime/build.ps1 -BuildRoot C:\os-runtime-build
```

Use a dedicated short build directory. No global SDK, drive, ACL, shell or Node
configuration is changed. The build retains Node/npm and PowerShell licenses.
Generated `x64/` is ignored and copied by electron-builder outside app.asar.
`build.json` is written last; incomplete builds fail closed at runtime.
The same staged directory is used by `npm run dev`.

Notebook children receive Node's standard `--preserve-symlinks` and
`--preserve-symlinks-main` options. This extends the REPL's existing entry-point
handling to npm and descendant Node processes: module loading must not enumerate
ungranted ancestors. Module identity follows the supplied path (including any
symlink), as documented for these Node options. Arbitrary host `NODE_OPTIONS` is
not inherited. npm uses `cache/notebook/npm` in the existing disposable workload
cache; it does not write the host user's npm cache or the bundled runtime.

Run the real AppContainer regression on a machine with the installed product's
owned sandbox profile (normal unit tests do not provision machine resources):

```powershell
$env:RUN_WINDOWS_NOTEBOOK_RUNTIME = '1'
npx vitest run packages/notebook-network-sandbox/src/windows-notebook-runtime.integration.test.ts
```

New Shell bindings record PowerShell `7.6`. Historical `5.1` bindings remain
readable and retain their original interpreter identity. There is no database
migration or new execution state. Re-running a historical cell uses the selected
Session runtime, as before. A source build is not a vendor-signed runtime; Windows
release packaging must include these artifacts in its normal signing process.
