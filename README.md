# DotNetRuntimeSDK

Single SDK repository for both managed runtimes the UnrealSharp plugin hosts:

| backend | dotnet/runtime line | payloads | host |
| --- | --- | --- | --- |
| Mono | `v10.0.14` (10.0.x servicing) | Win64/x64, Mac/{x64,arm64}, Linux/x64, Android/arm64, IOS/arm64, IOSSimulator/arm64 | CSMonoRuntime (embedding API) |
| CoreCLR | `v11.0.0-rc.3...` (11 until GA) | Android/arm64, IOS/arm64, IOSSimulator/arm64 | raw `coreclr_initialize` (mobile), hostfxr (desktop) |

`DotNetRuntime.version` is the single source of truth (`MONO_SOURCE_TAG`,
`SOURCE_TAG` = CoreCLR, `BUILD_SUBSET`, TFMs). One line moves a backend to a new
source; CI and the build scripts all read it.

## Consumers

The plugin mounts this repo as `Source/ThirdParty/DotNetRuntimeSDK/` (submodule).
`DotNetRuntimeSDK.Build.cs` resolves the backend per target (layered ini keys
`DotNetRuntime` / `DotNetRuntimeEditor`) and selects include paths, libraries and
staging accordingly. Payloads are git-ignored.

## Production

- CI: `.github/workflows/build-all.yml` - 10 concurrent legs (mono 7 + coreclr 3),
  independently dispatchable per leg; artifacts upload `Mono/<Platform>/<arch>/` and
  `CoreCLR/<Platform>/<arch>/`. `package-release.yml` zips them into a GitHub Release.
- Local: `BuildMonoSDK.sh <dotnet-runtime-src> <platform> [Debug|Release] [arch]`,
  `BuildCoreClrSDK.sh <dotnet-runtime-src> <platform> [Debug|Release] [arch]`.
- Fetch: `FetchRuntimeSDK.sh --tag <release-tag> <platform>` (CoreCLR payloads; mono
  assets follow the same release once package-release runs for them).

## Provenance

Every payload dir carries `VERSION.txt` stamped by the copy script:
source repo, branch, commit, platform, `Runtime: <version> (<tfm>)`, build type and
subsets. `DotNetRuntimeSDK.Build.cs` verifies the CoreCLR payload major against the
version file at build time.
