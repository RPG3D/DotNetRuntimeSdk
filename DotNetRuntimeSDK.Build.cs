// DotNetRuntimeSDK.Build.cs
// The single UBT External module for both managed runtimes (Mono and CoreCLR).
//
// Responsibilities:
//   - Resolves the runtime backend (RuntimeBackend.cs: layered ini override chain) and
//     bakes UNREALSHARP_MONO=1/0 (propagated via the Public dependency chain)
//   - MONO:  links/stages the Mono payload for Win64, Mac, Android, IOS, IOSSimulator
//   - CORECLR: links/stages the CoreCLR payload for Android, IOS, IOSSimulator
//     (desktop CoreCLR is the upstream hostfxr path - no payload, nothing to link)
//   - Exposes both backends' headers (Mono/include, CoreCLR/include)
//   - Pre-signs nested framework dylibs (Mono.framework / CoreCLR.framework) for iOS
//
// Consumers:
//   - UnrealSharpCore        PublicDependencyModuleNames - macro + includes propagate
//   - UnrealSharpUtilities   needs the macro in its own sources
//   - UnrealSharpProcHelper  PrivateDependencyModuleNames - dep direction reversed
//
// Layout (this directory IS the SDK root; payloads are git-ignored, produced by CI
// (.github/workflows/build-all.yml) or the local build scripts):
//   DotNetRuntime.version        single source: SOURCE_TAG / BUILD_SUBSET per backend
//   Mono/<Platform>/<arch>/      mono payload (Win64 Mac Linux Android IOS IOSSimulator)
//   Mono/include/                shared mono headers (superset from the Win64 build)
//   CoreCLR/<Platform>/<arch>/   coreclr payload (Android IOS IOSSimulator)
//   CoreCLR/include/             coreclrhost.h + host_runtime_contract.h
//   BuildMonoSDK.sh|.bat / MakeMonoFramework.sh / CopyMonoSDKFromSrc.sh|.bat
//   BuildCoreClrSDK.sh / CopyCoreClrSDKFromSrc.sh / MakeCoreClrFramework.sh
//   FetchRuntimeSDK.sh           GitHub-Releases fetch (RPG3D/DotNetRuntimeSDK)
//   MonoSDK_APL.xml / CoreClrSDK_APL.xml

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using EpicGames.Core;
using Microsoft.Extensions.Logging;
using UnrealBuildTool;

// RuntimeBackend (part of DotNetRuntimeSDK.Build.cs)
// Runtime-backend resolver shared by every consumer that needs the backend decision at
// UBT time (DotNetRuntimeSDK linkage, UnrealSharpCore hostfxr includes). UBT compiles all
// Build.cs into one rules assembly, so this class is callable from other Build.cs files.
//
// The backend is baked into EACH target binary at its own build time: an Android game
// target evaluates Android → Mono, while the Win64 editor target evaluates Win64 → its
// own choice. A cook run by UnrealEditor-Cmd therefore always executes the EDITOR
// target's backend, never the cooked target's — no runtime coupling there.
//
// Runtime-backend selection as a layered override chain, mirroring UE's ini hierarchy
// philosophy (general → specific, later layers win):
//   layer 0 (base):    platform default — editor targets: CoreCLR (upstream editor);
//                      game targets: Android/iOS → Mono (no CoreCLR mobile host on this
//                      branch), Win64/Mac/Linux → CoreCLR (upstream hostfxr mechanism)
//   layer 1:           [UnrealSharp] DotNetRuntime=Mono|CoreCLR — global intent; the ini
//                      hierarchy is read with Target.Platform, so AndroidEngine.ini etc.
//                      refine it per platform
//   layer 2:           [UnrealSharp] DotNetRuntimeEditor=Mono|CoreCLR — editor-target
//                      override (e.g. editor Mono for debugging while packaged stays CoreCLR)
public static class UnrealSharpRuntimeSelection
{
	public static bool ShouldUseMono(ReadOnlyTargetRules Target)
	{
		// Layer 0 — platform default.
		bool bUseMono = Target.bBuildEditor
			? false // editors are desktop-only; upstream editor default is CoreCLR
			: (Target.Platform == UnrealTargetPlatform.Android || Target.Platform == UnrealTargetPlatform.IOS);

		// Layer 1 — global key (platform ini layering applies).
		if (EngineIniGetString(Target, "DotNetRuntime", out string DotNetRuntime)
			&& TryParseRuntime(DotNetRuntime, "DotNetRuntime", out bool bMono))
		{
			bUseMono = bMono;
		}

		// Layer 2 — editor-target override.
		if (Target.bBuildEditor
			&& EngineIniGetString(Target, "DotNetRuntimeEditor", out string EditorOverride)
			&& TryParseRuntime(EditorOverride, "DotNetRuntimeEditor", out bool bEditorMono))
		{
			bUseMono = bEditorMono;
		}

		return bUseMono;
	}

	private static bool EngineIniGetString(ReadOnlyTargetRules Target, string Key, out string Value)
	{
		ConfigHierarchy EngineIni = ConfigCache.ReadHierarchy(
			ConfigHierarchyType.Engine,
			DirectoryReference.FromFile(Target.ProjectFile),
			Target.Platform);
		return EngineIni.GetString("UnrealSharp", Key, out Value);
	}

	private static bool TryParseRuntime(string Value, string Key, out bool bMono)
	{
		if (Value.Equals("Mono", StringComparison.OrdinalIgnoreCase))
		{
			bMono = true;
			return true;
		}
		if (Value.Equals("CoreCLR", StringComparison.OrdinalIgnoreCase))
		{
			bMono = false;
			return true;
		}
		Log.TraceWarning("UnrealSharp: invalid {0} value '{1}' (expected Mono or CoreCLR); ignoring.", Key, Value);
		bMono = false;
		return false;
	}
}

public class DotNetRuntimeSDK : ModuleRules
{
    // ModuleDirectory IS the SDK root.
    private readonly string sdkRoot;

    public DotNetRuntimeSDK(ReadOnlyTargetRules Target) : base(Target)
    {
        Type = ModuleType.External;

        sdkRoot = ModuleDirectory;

        // ── ini invalidation ───────────────────────────────────────────────────────
        // The ini files feeding UnrealSharpRuntimeSelection are NOT tracked by UBT's
        // TargetMakefile (ConfigCache reads are invisible to makefile invalidation), so
        // a DotNetRuntime/DotNetRuntimeEditor switch alone would silently keep the stale
        // backend. Register them as external dependencies so any change re-runs the
        // rules (and re-bakes UNREALSHARP_MONO). UBT's Engine hierarchy layers read the
        // PLATFORM-SUBDIR form (Config/Android/AndroidEngine.ini), not the runtime-style
        // flat Config/AndroidEngine.ini - see EnumerateConfigFileLocations.
        if (Target.ProjectFile != null)
        {
            string ProjectConfigDir = Path.Combine(Path.GetDirectoryName(Target.ProjectFile.FullName)!, "Config");
            foreach (string IniName in new[] { "DefaultEngine.ini", "Android/AndroidEngine.ini", "IOS/IOSEngine.ini", "Windows/WindowsEngine.ini", "Mac/MacEngine.ini" })
            {
                string IniPath = Path.Combine(ProjectConfigDir, IniName);
                if (File.Exists(IniPath))
                {
                    ExternalDependencies.Add(IniPath);
                }
            }
        }

        bool bUseMono = UnrealSharpRuntimeSelection.ShouldUseMono(Target);

        if (bUseMono)
        {
            // UnrealTargetPlatform is a static class, not an enum - comparisons only,
            // no switch/case constants.
            if (Target.Platform == UnrealTargetPlatform.Mac)
            {
                ConfigureMonoMac(Target);
            }
            else if (Target.Platform == UnrealTargetPlatform.Android)
            {
                ConfigureMonoAndroid(Target);
            }
            else if (Target.Platform == UnrealTargetPlatform.IOS)
            {
                ConfigureMonoIos(Target);
            }
            else if (Target.Platform == UnrealTargetPlatform.Win64)
            {
                ConfigureMonoWin64(Target);
            }
            else
            {
                // e.g. a Linux game target with DotNetRuntime=Mono: no mono branch is
                // wired for it (same as the pre-merge module). Fall through to the
                // CoreCLR-side define so the #if guards stay consistent.
                Logger.LogWarning("DotNetRuntimeSDK: Mono requested for {0} but no mono linkage exists for it; baking UNREALSHARP_MONO=0 (CoreCLR path).",
                    Target.Platform);
                PublicDefinitions.Add("UNREALSHARP_MONO=0");
            }
        }
        else
        {
            PublicDefinitions.Add("UNREALSHARP_MONO=0");
            ConfigureCoreClr(Target);
        }

        StageProjectManagedDlls(Target, bUseMono);
    }

    // ────────────────────────────────────────────────────────────────────── MONO ──

    private string MonoRoot => Path.Combine(sdkRoot, "Mono");

    private void ConfigureMonoMac(ReadOnlyTargetRules Target)
    {
        PublicDefinitions.Add("UNREALSHARP_MONO=1");

        // macOS ships both an x64 and an arm64 SDK (Mac/x64, Mac/arm64), so the
        // directory is resolved per target architecture. The legacy flat Mac/ dir
        // (arm64-only SDKs from before the arch split) is still accepted.
        string monoPlatformDir = ResolveMonoPlatformDir(MonoRoot, "Mac", Target.Architecture);
        string monoLib = Path.Combine(monoPlatformDir, "lib");
        string monoRuntime = Path.Combine(monoPlatformDir, "runtime");

        PublicIncludePaths.Add(ResolveMonoIncludeDir(monoPlatformDir));

        // Link libcoreclr.dylib (Mono runtime; named "coreclr" per Microsoft unified naming).
        // Its install_name is @rpath/libcoreclr.dylib (dotnet/runtime sets MACOSX_RPATH ON),
        // so dyld resolves it from an LC_RPATH, not from this path. The linker records the
        // install_name, not the path passed here.
        string monoLibPath = Path.Combine(monoLib, "libcoreclr.dylib");
        PublicAdditionalLibraries.Add(monoLibPath);

        // Stage it next to the executable (same pattern as Win64's coreclr.dll). The rpath
        // that makes it resolvable comes from UBT itself: MacToolChain adds
        // "-rpath @loader_path/ -rpath @executable_path/" for every non-library link, and for
        // monolithic builds it additionally derives a staged rpath per .dylib in
        // RuntimeDependencies. PublicRuntimeLibraryPaths is NOT the mechanism to use here --
        // only LinuxToolChain reads LinkEnvironment.RuntimeLibraryPaths.
        RuntimeDependencies.Add("$(BinaryOutputDir)/libcoreclr.dylib", monoLibPath);

        // Native interop dylibs - BCL DllImport targets, all with @rpath install names.
        // Staged next to the executable so the same @executable_path rpath resolves them.
        //
        // They can arrive in either subdirectory, so both are searched:
        //   lib/     - CopyMonoSDKFromSrc.sh copies them there from artifacts/bin/native/<TFM>
        //   runtime/ - dotnet/runtime bin-places $(NativeBinDir)*.dylib into the runtime
        //              artifact, which the script copies wholesale into runtime/
        string[] nativeDylibs =
        {
            "libSystem.Native.dylib",
            "libSystem.Globalization.Native.dylib",
            "libSystem.IO.Compression.Native.dylib",
            "libSystem.IO.Ports.Native.dylib",
            "libSystem.Net.Security.Native.dylib",
            "libSystem.Security.Cryptography.Native.Apple.dylib",
        };
        foreach (string name in nativeDylibs)
        {
            string path = FindInPlatformDir(monoLib, monoRuntime, name);
            if (path != null)
                RuntimeDependencies.Add("$(BinaryOutputDir)/" + name, path);
        }

        // BCL managed DLLs - staged as NonUFS (outside PAK, alongside the executable).
        // BCL is tied to the Mono runtime version and should not be hot-updated via PAK.
        // Mono's assembly preload hook searches Saved/ override dir first, then these BCL DLLs.
        if (Directory.Exists(monoRuntime))
        {
            RuntimeDependencies.Add(Path.Combine(monoRuntime, "...*.dll"), StagedFileType.NonUFS);
        }
    }

    private void ConfigureMonoAndroid(ReadOnlyTargetRules Target)
    {
        PublicDefinitions.Add("UNREALSHARP_MONO=1");

        // Every platform keeps its SDK at <Platform>/<arch>/; Android is arm64-only.
        string monoPlatformDir = ResolveMonoPlatformDir(MonoRoot, "Android", Target.Architecture);
        string monoLib = Path.Combine(monoPlatformDir, "lib");
        string monoRuntime = Path.Combine(monoPlatformDir, "runtime");

        PublicIncludePaths.Add(ResolveMonoIncludeDir(monoPlatformDir));

        // Link libmonosgen-2.0.so at compile time (linker -l flag).
        // All .so files are packaged into APK lib/arm64-v8a/ via MonoSDK_APL.xml.
        PublicAdditionalLibraries.Add(Path.Combine(monoLib, "libmonosgen-2.0.so"));

        string aplPath = Path.Combine(ModuleDirectory, "MonoSDK_APL.xml");
        AdditionalPropertiesForReceipt.Add("AndroidPlugin", aplPath);

        // BCL managed DLLs - mapped UFS into Content/Managed/Android (no physical copy).
        // The preload hook serves them from the PAK, exactly like iOS, so the runtime
        // never depends on a native SDK path inside the APK.
        if (Directory.Exists(monoRuntime))
        {
            foreach (string BclFile in Directory.EnumerateFiles(monoRuntime, "*.dll"))
            {
                string BclDest = "$(ProjectDir)/Content/Managed/Android/" + Path.GetFileName(BclFile);
                RuntimeDependencies.Add(BclDest, BclFile, StagedFileType.UFS);
            }
            // Sidecar PDBs for the soft debugger: the host preloads them from the PAK
            // and passes them to mono_debug_open_image_from_memory.
            foreach (string BclPdb in Directory.EnumerateFiles(monoRuntime, "*.pdb"))
            {
                string PdbDest = "$(ProjectDir)/Content/Managed/Android/" + Path.GetFileName(BclPdb);
                RuntimeDependencies.Add(PdbDest, BclPdb, StagedFileType.UFS);
            }
        }
    }

    private void ConfigureMonoIos(ReadOnlyTargetRules Target)
    {
        // UBT uses Target.Platform == IOS for BOTH real device and Simulator.
        // The architecture distinguishes them:
        //   UnrealArch.Arm64         -> real iOS device   (Mono/IOS/)
        //   UnrealArch.IOSSimulator  -> iOS Simulator     (Mono/IOSSimulator/<arch>/)
        //
        // The two sets of static libs are ABI-incompatible and MUST NOT be mixed.
        //
        // iOS forbids JIT (W^X); Mono runs in INTERP+AOT mode:
        //   - System.Private.CoreLib.dll.a : pre-AOT CoreLib (mono-aot-cross output)
        //   - libmonosgen-2.0.a            : Mono runtime (static)
        //   - stub component variants      : minimal IPA footprint
        //   - libSystem.Globalization.Native.a : Globalization stubs (INVARIANT mode)
        //   - Mono.embeddedframework.zip   : native interop dylibs -> IPA Frameworks/

        PublicDefinitions.Add("UNREALSHARP_MONO=1");

        bool bIsSimulator = (Target.Architecture == UnrealArch.IOSSimulator);
        string platformName = bIsSimulator ? "IOSSimulator" : "IOS";

        // Both layouts keep <Platform>/<arch>/: the device is IOS/arm64, the simulator
        // is IOSSimulator/arm64 (UE 5.7) or IOSSimulator/x64 on engine lines that
        // expose a simulator architecture.
        string monoPlatformDir = bIsSimulator
            ? ResolveMonoPlatformDir(MonoRoot, platformName, GetIOSSimulatorArchName())
            : ResolveMonoPlatformDir(MonoRoot, platformName, Target.Architecture);

        string monoLib = Path.Combine(monoPlatformDir, "lib");

        PublicIncludePaths.Add(ResolveMonoIncludeDir(monoPlatformDir));

        // CoreLib AOT static lib (REQUIRED: prevents W^X violation at runtime bootstrap)
        PublicAdditionalLibraries.Add(Path.Combine(monoLib, "System.Private.CoreLib.dll.a"));

        // Mono runtime (static)
        PublicAdditionalLibraries.Add(Path.Combine(monoLib, "libmonosgen-2.0.a"));

        // Mono components - stub variants keep IPA size small.
        // Only marshal-ilgen uses the full variant (IL code gen required for BCL interop).
        PublicAdditionalLibraries.Add(Path.Combine(monoLib, "libmono-component-debugger-stub-static.a"));
        PublicAdditionalLibraries.Add(Path.Combine(monoLib, "libmono-component-diagnostics_tracing-stub-static.a"));
        PublicAdditionalLibraries.Add(Path.Combine(monoLib, "libmono-component-hot_reload-stub-static.a"));
        PublicAdditionalLibraries.Add(Path.Combine(monoLib, "libmono-component-marshal-ilgen-static.a"));

        // Globalization stubs (DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 is set at runtime).
        //
        // Link the STATIC variant (.a) via absolute path to avoid a dyld path mismatch
        // at runtime.  Mono.embeddedframework.zip places the dylib inside
        // Mono.framework/Frameworks/, but the main binary's @rpath only resolves to
        // the IPA root Frameworks/ dir.  Using PublicSystemLibraryPaths+PublicSystemLibraries
        // caused the Apple linker to prefer the .dylib over the .a when both are present in
        // monoLib, producing @rpath/libSystem.Globalization.Native.dylib in the binary which
        // dyld cannot resolve at runtime. Using the absolute .a path forces static linkage.
        PublicAdditionalLibraries.Add(Path.Combine(monoLib, "libSystem.Globalization.Native.a"));

        // Native interop dylibs packaged as embedded framework into IPA Frameworks/.
        // FrameworkMode.Copy (not Link): Mono.embeddedframework.zip is an umbrella framework
        // whose top-level binary is intentionally empty - the runtime is already statically
        // linked via libmonosgen-2.0.a. We only need the sub-Frameworks copied into IPA.
        PublicAdditionalFrameworks.Add(new Framework(
            "Mono",
            Path.Combine(monoLib, "Mono.embeddedframework.zip"),
            Framework.FrameworkMode.Copy,
            null));

        // Pre-sign the dylibs inside Mono.embeddedframework.zip so the packaged IPA
        // passes on-device code-sign validation. UE signs the outer app bundle but
        // does NOT recurse into the nested Mono.framework/Frameworks/ dylibs.
        // macOS host only (native iOS UBT); a no-op on Windows or for the Simulator.
        if (!bIsSimulator)
        {
            SignEmbeddedFrameworkZip(Path.Combine(monoLib, "Mono.embeddedframework.zip"), "MonoSDK");
        }

        // BCL managed DLLs - staged as UFS in Content/Managed/IOS.
        // The UnrealSharp preload hook is invoked for corlib during mono_jit_init and
        // reads it through UE's file manager, so the PAK copy is what the runtime needs.
        string monoRuntime = Path.Combine(monoPlatformDir, "runtime");
        StageDirectoryAsUfs(monoRuntime, "$(ProjectDir)/Content/Managed/IOS/", "*.dll");
        StageDirectoryAsUfs(monoRuntime, "$(ProjectDir)/Content/Managed/IOS/", "*.pdb");
    }

    private void ConfigureMonoWin64(ReadOnlyTargetRules Target)
    {
        PublicDefinitions.Add("UNREALSHARP_MONO=1");

        // Every platform keeps its SDK at <Platform>/<arch>/; Win64 is x64-only.
        string monoPlatformDir = ResolveMonoPlatformDir(MonoRoot, "Win64", Target.Architecture);
        string monoLib = Path.Combine(monoPlatformDir, "lib");
        string monoRuntime = Path.Combine(monoPlatformDir, "runtime");

        PublicIncludePaths.Add(ResolveMonoIncludeDir(monoPlatformDir));

        // Dynamic link: import lib at compile time; coreclr.dll copied to Binaries/Win64/.
        // Two-argument RuntimeDependencies.Add(dest, src) triggers the build-time copy.
        string importLib = Path.Combine(monoLib, "coreclr.import.lib");
        string coreclrDll = Path.Combine(monoLib, "coreclr.dll");
        PublicAdditionalLibraries.Add(importLib);
        RuntimeDependencies.Add("$(BinaryOutputDir)/coreclr.dll", coreclrDll);

        // BCL managed DLLs - staged as NonUFS (outside PAK).
        if (Directory.Exists(monoRuntime))
        {
            RuntimeDependencies.Add(Path.Combine(monoRuntime, "...*.dll"), StagedFileType.NonUFS);
        }
    }

    // ──────────────────────────────────────────────────────────────────── CORECLR ──

    private void ConfigureCoreClr(ReadOnlyTargetRules Target)
    {
        // CoreCLR-on-mobile is active only on the mobile platforms; desktop runs the
        // upstream hostfxr path (no payload, nothing to link or stage here).
        bool bMobileCoreClr = Target.Platform == UnrealTargetPlatform.Android
            || Target.Platform == UnrealTargetPlatform.IOS;

        if (!bMobileCoreClr)
        {
            return;
        }

        // SDK payload layout is <Platform>/<arch>/; Android is arm64-only, iOS device is
        // arm64-only, the simulator rides its own dir.
        string bclSdkDir = Target.Platform == UnrealTargetPlatform.Android
            ? "Android/arm64"
            : (Target.Architecture == UnrealArch.IOSSimulator ? "IOSSimulator/arm64" : "IOS/arm64");

        string contentPakDir = Target.Platform == UnrealTargetPlatform.Android ? "Android" : "IOS";
        string payloadDir = Path.Combine(sdkRoot, "CoreCLR", bclSdkDir);
        string bclRuntimeDir = Path.Combine(payloadDir, "runtime");

        // Refuse a payload built from a different runtime branch than DotNetRuntime.version
        // pins: a wrong-branch payload links fine and only fails on device (no interpreter
        // on 10/iOS, CoreLib mismatch). See VerifyPayloadRuntimeMajor for the details.
        string contentPlatformKey = Target.Platform == UnrealTargetPlatform.Android ? "ANDROID" : "IOS";
        VerifyPayloadRuntimeMajor(payloadDir, contentPlatformKey);

        // Host headers (coreclrhost.h / host_runtime_contract.h) are NOT stored in git:
        // CopyCoreClrSDKFromSrc.sh extracts them from the pinned dotnet/runtime source
        // into the payload's include/, and CI artifacts carry it. coreclrhost.h is only
        // compiled on mobile CoreCLR targets (CSDotNetRuntimeHost.h guards); desktop
        // uses the plugin's own hostfxr headers from Managed/DotNetRuntime/inc.
        string payloadInclude = Path.Combine(payloadDir, "include");
        string legacyInclude = Path.Combine(sdkRoot, "CoreCLR", "include");
        if (Directory.Exists(payloadInclude))
        {
            PublicIncludePaths.Add(payloadInclude);
        }
        else if (Directory.Exists(legacyInclude))
        {
            Logger.LogWarning("DotNetRuntimeSDK: using legacy {0}; regenerate the payload so include/ ships inside it.", legacyInclude);
            PublicIncludePaths.Add(legacyInclude);
        }
        else
        {
            throw new BuildException(
                $"CoreCLR host headers not found. Expected '{payloadInclude}' (inside the payload) " +
                $"or '{legacyInclude}'. Rebuild the payload with CopyCoreClrSDKFromSrc.sh, which " +
                "extracts them from the pinned dotnet/runtime source.");
        }

        if (Directory.Exists(bclRuntimeDir))
        {
            foreach (string bclDll in Directory.GetFiles(bclRuntimeDir, "*.dll"))
            {
                RuntimeDependencies.Add(
                    $"$(ProjectDir)/Content/Managed/{contentPakDir}/{Path.GetFileName(bclDll)}",
                    bclDll,
                    StagedFileType.UFS);
            }
        }

        if (Target.Platform == UnrealTargetPlatform.Android)
        {
            string nativeLibDir = Path.Combine(sdkRoot, "CoreCLR", "Android", "arm64", "lib");

            string coreclrLibPath = Path.Combine(nativeLibDir, "libcoreclr.so");
            if (File.Exists(coreclrLibPath))
            {
                PublicAdditionalLibraries.Add(coreclrLibPath);
            }

            string aplPath = Path.Combine(ModuleDirectory, "CoreClrSDK_APL.xml");
            if (File.Exists(aplPath))
            {
                AdditionalPropertiesForReceipt.Add("AndroidPlugin", aplPath);
            }
        }

        if (Target.Platform == UnrealTargetPlatform.IOS)
        {
            bool bIsSimulator = Target.Architecture == UnrealArch.IOSSimulator;
            string platformDir = bIsSimulator ? "IOSSimulator/arm64" : "IOS/arm64";
            string nativeLibDir = Path.Combine(sdkRoot, "CoreCLR", platformDir, "lib");

            // iOS requires dynamic libraries in an embedded framework (scatter dylibs
            // in .app root is rejected by App Store / fails device install). All CoreCLR
            // native dylibs are packaged into a single CoreCLR.embeddedframework.zip by
            // MakeCoreClrFramework.sh. LinkAndCopy links coreclr_* symbols from the
            // framework binary and copies the whole framework into .app/Frameworks/.
            string frameworkZip = Path.Combine(nativeLibDir, "CoreCLR.embeddedframework.zip");
            if (!File.Exists(frameworkZip))
            {
                throw new BuildException(
                    $"CoreCLR.embeddedframework.zip not found at {frameworkZip}. " +
                    "Run MakeCoreClrFramework.sh to build the single iOS framework.");
            }

            // UE signs the outer app and the framework bundle, but never recurses into
            // CoreCLR.framework/{Frameworks,libclrjit,libclrinterpreter}. An unsigned dylib
            // cannot be dlopen'ed on device (EPERM), and the failure surfaces far away: the
            // first P/Invoke (libSystem.Native during SR message formatting) throws
            // DllNotFoundException, whose message lookup re-enters globalization and ends in
            // FailFast. Pre-sign the nested Mach-O files here, before UE seals the framework.
            SignEmbeddedFrameworkZip(frameworkZip, "CoreClrSDK");

            PublicAdditionalFrameworks.Add(new Framework(
                "CoreCLR",
                frameworkZip,
                Framework.FrameworkMode.LinkAndCopy,
                null));
        }
    }

    // ─────────────────────────────────────────────────────────── shared staging ──

    /// <summary>
    /// Project managed DLLs (per-platform publish output) stage as UFS into the PAK for
    /// every backend that consumes Content/Managed/<Platform>. Desktop Mono also stages
    /// them (Win64/Mac), matching the pre-merge MonoSDK behavior.
    /// </summary>
    private void StageProjectManagedDlls(ReadOnlyTargetRules Target, bool bUseMono)
    {
        string managedPlatformDir = null;

        if (bUseMono && Target.ProjectFile != null)
        {
            managedPlatformDir = Target.Platform.ToString();
            // IOS uses the same UnrealTargetPlatform for device and simulator;
            // distinguish via architecture so simulator builds pick up IOSSimulator/.
            if (Target.Platform == UnrealTargetPlatform.IOS && Target.Architecture == UnrealArch.IOSSimulator)
                managedPlatformDir = "IOSSimulator";
        }
        else if (!bUseMono
                 && (Target.Platform == UnrealTargetPlatform.Android || Target.Platform == UnrealTargetPlatform.IOS))
        {
            // CoreCLR mobile: same UFS staging the pre-merge CoreClrSDK performed
            // (device and simulator both publish into Content/Managed/IOS).
            managedPlatformDir = Target.Platform == UnrealTargetPlatform.Android ? "Android" : "IOS";
        }

        if (managedPlatformDir == null || Target.ProjectFile == null)
            return;

        string projectDir = Path.GetDirectoryName(Target.ProjectFile.FullName)!;
        string managedContentDir = Path.Combine(projectDir, "Content", "Managed", managedPlatformDir);
        if (Directory.Exists(managedContentDir))
        {
            RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.dll"), StagedFileType.UFS);
            RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.pdb"), StagedFileType.UFS);
            RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.json"), StagedFileType.UFS);
        }
    }

    /// <summary>
    /// Stage every file matching <paramref name="pattern"/> in <paramref name="sourceDir"/>
    /// as UFS under <paramref name="destPrefix"/> + filename. No-op when the dir is absent.
    /// </summary>
    private void StageDirectoryAsUfs(string sourceDir, string destPrefix, string pattern)
    {
        if (!Directory.Exists(sourceDir))
            return;

        foreach (string file in Directory.EnumerateFiles(sourceDir, pattern))
        {
            RuntimeDependencies.Add(destPrefix + Path.GetFileName(file), file, StagedFileType.UFS);
        }
    }

    // ─────────────────────────────────────────────────────── mono path helpers ──

    // The Mono headers are not per-platform data and are not tracked in git: the Win64
    // x64 build emits the superset (it adds the jit.h variants the other platforms'
    // builds omit). Resolve the backend-root copy first (Mono/include), then the platform
    // directory (a freshly extracted artifact set where the root copy was never
    // assembled), and fail with instructions when neither exists.
    private string ResolveMonoIncludeDir(string monoPlatformDir)
    {
        string RootInclude = Path.Combine(MonoRoot, "include");
        if (Directory.Exists(RootInclude))
        {
            return RootInclude;
        }

        string PlatformInclude = Path.Combine(monoPlatformDir, "include");
        if (Directory.Exists(PlatformInclude))
        {
            Logger.LogWarning("DotNetRuntimeSDK: Mono/include not found; using {0}. Run " +
                "package-release.yml or copy Win64/x64/include to Mono/include.", PlatformInclude);
            return PlatformInclude;
        }

        throw new BuildException(
            $"Mono headers not found. Expected '{RootInclude}' (the shared copy) or '{PlatformInclude}'.\n" +
            "Populate Mono/ by downloading the DotNetRuntimeSDK release zip (ships include/ at " +
            "Mono/) or by extracting the MonoSDK-Windows-x64 artifact and copying " +
            "Win64/x64/include to Mono/include.");
    }

    // Every platform keeps its SDK at <Platform>/<arch>/ -- Win64/x64, Android/arm64,
    // IOS/arm64, Linux/x64, Mac/{x64,arm64}, IOSSimulator/{arm64,x64} -- so one rule
    // covers all of them and a platform can gain an architecture without touching the
    // consumers. The pre-arch-split flat form (<Platform>/) is still accepted as a
    // fallback so an SDK downloaded before the layout change keeps working.
    //
    // Throws a BuildException when neither exists: a missing SDK otherwise surfaces
    // as an obscure linker error, and the fix (run the SDK build workflow, or
    // download the release zip) is not guessable from that message.
    private string ResolveMonoPlatformDir(string monoRoot, string platformName, UnrealArch architecture)
    {
        string archName;
        if (architecture == UnrealArch.Arm64)
        {
            archName = "arm64";
        }
        else if (architecture == UnrealArch.X64)
        {
            archName = "x64";
        }
        else
        {
            throw new BuildException(
                $"DotNetRuntimeSDK: no arch mapping for UnrealArch.{architecture} on {platformName}. " +
                "Add the arch to ResolveMonoPlatformDir() and to the BuildMonoSDK.sh matrix.");
        }

        return ResolveMonoPlatformDir(monoRoot, platformName, archName);
    }

    private string ResolveMonoPlatformDir(string monoRoot, string platformName, string archName)
    {
        // Requires real SDK payload (lib/ or runtime/), not merely an existing directory:
        // the release workflow creates Mac/<arch>/ before downloading, so a failed download
        // leaves an empty directory behind, and a bare Mac/ containing only that subdirectory
        // would otherwise pass a "non-empty" test. Either way the result would be a confusing
        // missing-dylib failure instead of the error below.
        string archDir = Path.Combine(monoRoot, platformName, archName);
        if (HasMonoSdkPayload(archDir))
        {
            return archDir;
        }

        string flatDir = Path.Combine(monoRoot, platformName);
        if (HasMonoSdkPayload(flatDir))
        {
            Logger.LogWarning("DotNetRuntimeSDK: using legacy flat directory {0} (no populated {1}/ subdirectory). " +
                "Rebuild the SDK with the arch-aware BuildMonoSDK.sh to get per-arch directories.",
                flatDir, archName);
            return flatDir;
        }

        throw new BuildException(
            $"Mono payload for {platformName} ({archName}) not found. Expected '{archDir}'.\n" +
            $"Populate it by running the 'Build DotNetRuntimeSDK - All Platforms' GitHub workflow " +
            $"(platform={platformName}, arch={archName}) and extracting the artifact, or download the " +
            $"release zip and copy Mono/{platformName}/{archName}/ into the SDK directory.\n" +
            $"Alternatively set DotNetRuntime=CoreCLR in Config/DefaultEngine.ini to use the CoreCLR backend.");
    }

    /// <summary>
    /// True when the directory holds Mono payload. BuildMonoSDK.sh always produces
    /// lib/ (native libraries) and runtime/ (BCL), so requiring one of them distinguishes a
    /// real SDK from a directory that merely exists.
    /// </summary>
    private static bool HasMonoSdkPayload(string platformDir)
    {
        return Directory.Exists(Path.Combine(platformDir, "lib"))
            || Directory.Exists(Path.Combine(platformDir, "runtime"));
    }

    /// <summary>
    /// First existing <paramref name="fileName"/> across the given platform subdirectories,
    /// or null when it is in none of them. Used where a file may legitimately live in more
    /// than one subdirectory depending on how the SDK was produced.
    /// </summary>
    private static string FindInPlatformDir(string firstDir, string secondDir, string fileName)
    {
        foreach (string dir in new[] { firstDir, secondDir })
        {
            string candidate = Path.Combine(dir, fileName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    /// <summary>
    /// Architecture name for an iOS Simulator target. UE 5.7 defines the simulator
    /// as a single arm64 architecture (see UEBuildIOS.cs: UnrealArch.IOSSimulator
    /// maps to clang "arm64"), so the SDK resolves to IOSSimulator/arm64. The x64
    /// simulator SDK is built for engine lines/toolchains that support it; wire it
    /// up here if a future engine exposes the simulator architecture.
    /// </summary>
    private string GetIOSSimulatorArchName()
    {
        return "arm64";
    }

    // ────────────────────────────────────────────── payload / version agreement ──
    //
    // The runtime branch follows the backend: Mono -> dotnet 10, CoreCLR -> dotnet 11
    // (11 dropped Mono from the coreclr tree; 10's iOS CoreCLR has no interpreter).
    // DotNetRuntime.version holds the expected major, and CopyCoreClrSDKFromSrc.sh
    // stamps the payload's VERSION.txt with "Runtime: <major>.<version> (<tfm>)". A payload
    // copied from the wrong branch links fine and only fails on device, so compare here.
    private void VerifyPayloadRuntimeMajor(string payloadDir, string platformKey)
    {
        string versionFilePath = Path.Combine(sdkRoot, "DotNetRuntime.version");
        if (!File.Exists(versionFilePath))
            return;

        string expected = ReadVersionKey(versionFilePath, "DOTNET_MAJOR", platformKey);
        if (string.IsNullOrEmpty(expected))
            return;

        string payloadVersionFile = Path.Combine(payloadDir, "VERSION.txt");
        if (!File.Exists(payloadVersionFile))
        {
            Logger.LogWarning("DotNetRuntimeSDK: {0} has no VERSION.txt; cannot confirm it is dotnet {1}.",
                payloadDir, expected);
            return;
        }

        string actual = null;
        foreach (string line in File.ReadAllLines(payloadVersionFile))
        {
            const string Prefix = "Runtime: ";
            if (!line.StartsWith(Prefix, StringComparison.Ordinal))
                continue;
            string value = line.Substring(Prefix.Length).Trim();
            int dot = value.IndexOf('.');
            actual = dot > 0 ? value.Substring(0, dot) : value;
            break;
        }

        if (actual == null)
        {
            Logger.LogWarning("DotNetRuntimeSDK: {0}/VERSION.txt predates the Runtime stamp; expected dotnet {1}.",
                payloadDir, expected);
            return;
        }

        if (actual != expected)
        {
            throw new BuildException(
                $"CoreCLR payload {payloadDir} is dotnet {actual}, but DotNetRuntime.version pins " +
                $"{platformKey} to dotnet {expected}. Regenerate the payload from the matching " +
                "dotnet/runtime worktree (CopyCoreClrSDKFromSrc.sh) or fix the version file.");
        }
    }

    private static string ReadVersionKey(string versionFilePath, string key, string platformKey)
    {
        string platformValue = null;
        string defaultValue = null;
        foreach (string rawLine in File.ReadAllLines(versionFilePath))
        {
            string line = rawLine.Trim();
            if (line.Length == 0 || line[0] == '#')
                continue;

            if (line.StartsWith(key + "_" + platformKey + "=", StringComparison.Ordinal))
                platformValue = line.Substring((key + "_" + platformKey + "=").Length).Trim();
            else if (line.StartsWith(key + "=", StringComparison.Ordinal))
                defaultValue = line.Substring((key + "=").Length).Trim();
        }

        return platformValue ?? defaultValue;
    }

    // ───────────────────────────────────── embedded framework pre-signing ──
    //
    // UE stages the embedded framework (Mono / CoreCLR) into the IPA and signs the outer
    // app, but does NOT recurse into the nested <X>.framework/Frameworks/ dylibs - pre-sign
    // them here so on-device validation passes. macOS host only (native iOS UBT).
    //
    // Skip cache (.framework_sign_cache.txt next to the zip) stores "<zip sha256> <identity
    // sha1>": the identity is part of the key on purpose, so a renewed certificate, a
    // different team or a manual<->automatic switch re-signs instead of reusing a signature
    // made by the old certificate. Any failure logs and continues - never breaks the build.
    private void SignEmbeddedFrameworkZip(string zipPath, string logPrefix)
    {
        if (!OperatingSystem.IsMacOS())
            return;

        if (!File.Exists(zipPath))
            return;

        string cachePath = Path.Combine(Path.GetDirectoryName(zipPath)!, ".framework_sign_cache.txt");
        try
        {
            string identity = FindCodeSigningIdentity(GetConfiguredSigningTeam());
            if (identity == null)
            {
                Logger.LogWarning("{0}: no code-signing identity found; framework signing skipped.", logPrefix);
                return;
            }

            if (IsInSignCache(cachePath, ComputeSha256(zipPath), identity))
            {
                Logger.LogInformation("{0}: {1} already signed; skipping.", logPrefix, Path.GetFileName(zipPath));
                return;
            }

            // Unzip -> codesign every Mach-O -> repack with the native zip.
            // Native zip keeps unix file modes (the Mono stub must stay executable)
            // and symlinks (-y); .NET's ZipArchive would flatten both.
            string workDir = Path.Combine(Path.GetTempPath(), "DotNetRuntimeSDKSign_" + Path.GetRandomFileName());
            string extractDir = Path.Combine(workDir, "extract");
            Directory.CreateDirectory(extractDir);
            File.Copy(zipPath, zipPath + ".bak", overwrite: true); // pristine original
            try
            {
                RunProcessCapture("/usr/bin/unzip", new[] { "-q", zipPath, "-d", extractDir }, checkExit: true);

                // Sign every Mach-O under the extracted framework: nested dylibs, engines
                // (clrjit/clrinterpreter, CoreCLR.framework root only) and the framework
                // binary. Enumerating recursively keeps this backend-agnostic.
                string embeddedRoot = Path.Combine(extractDir,
                    Path.GetFileNameWithoutExtension(zipPath)); // e.g. Mono.embeddedframework
                foreach (string machO in Directory.EnumerateFiles(embeddedRoot, "*", SearchOption.AllDirectories))
                {
                    string ext = Path.GetExtension(machO);
                    bool isDylib = ext == ".dylib";
                    bool isFrameworkBinary = Path.GetFileName(machO) is "Mono" or "CoreCLR";
                    if (!isDylib && !isFrameworkBinary)
                        continue;

                    RunProcessCapture("/usr/bin/codesign",
                        new[] { "-f", "-s", identity, "--timestamp=none", machO }, checkExit: true);
                }

                // Repack with the same top-level structure.
                string newZip = Path.Combine(workDir, Path.GetFileName(zipPath));
                RunProcessCapture("/usr/bin/zip",
                    new[] { "-X", "-y", "-q", "-r", newZip, Path.GetFileName(embeddedRoot) },
                    extractDir, checkExit: true);
                File.Copy(newZip, zipPath, overwrite: true);
            }
            finally
            {
                Directory.Delete(workDir, true);
            }

            AppendToSignCache(cachePath, ComputeSha256(zipPath), identity);
            Logger.LogInformation("{0}: {1} signed; pristine original kept at {2}.bak.",
                logPrefix, Path.GetFileName(zipPath), zipPath);
        }
        catch (Exception ex)
        {
            Logger.LogWarning("{0}: framework signing skipped due to error: {1}", logPrefix, ex.Message);
        }
    }

    /// <summary>
    /// Team identifier from Config/IOS/IOSEngine.ini (CodeSigningTeam), or null.
    /// </summary>
    private string GetConfiguredSigningTeam()
    {
        if (Target.ProjectFile == null)
            return null;

        string iniPath = Path.Combine(Target.ProjectFile.Directory.FullName, "Config", "IOS", "IOSEngine.ini");
        if (!File.Exists(iniPath))
            return null;

        foreach (string line in File.ReadAllLines(iniPath))
        {
            string trimmed = line.Trim();
            if (!trimmed.StartsWith("CodeSigningTeam=", StringComparison.Ordinal))
                continue;
            string team = trimmed.Substring("CodeSigningTeam=".Length).Trim();
            if (team.Length > 0)
                return team;
        }

        return null;
    }

    /// <summary>
    /// SHA-1 of a valid code-signing identity from the keychain, or null. The hash (not the
    /// display name) pins one certificate instance so codesign never resolves to a revoked
    /// or duplicate-name cert. When a team is configured, an identity whose display name
    /// carries that team is preferred; otherwise the first valid identity wins.
    /// </summary>
    private string FindCodeSigningIdentity(string preferredTeam)
    {
        (_, string stdout) =
            RunProcessCapture("/usr/bin/security", new[] { "find-identity", "-v", "-p", "codesigning" });

        string fallback = null;
        foreach (string line in stdout.Split('\n'))
        {
            if (line.Contains("CSSMERR_", StringComparison.Ordinal))
                continue;
            string[] parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2 || parts[1].Length != 40 || !IsHexString(parts[1]))
                continue;

            if (preferredTeam != null && line.Contains(preferredTeam, StringComparison.Ordinal))
                return parts[1];

            fallback ??= parts[1];
        }

        return fallback;
    }

    private static bool IsHexString(string value)
    {
        foreach (char c in value)
        {
            bool bIsHexDigit = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!bIsHexDigit)
                return false;
        }

        return value.Length > 0;
    }

    private string ComputeSha256(string path)
    {
        return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
    }

    private bool IsInSignCache(string cachePath, string hash, string identity)
    {
        if (!File.Exists(cachePath))
            return false;

        string expected = hash + " " + identity;
        return File.ReadAllLines(cachePath).Any(line => line.StartsWith(expected, StringComparison.OrdinalIgnoreCase));
    }

    private void AppendToSignCache(string cachePath, string hash, string identity)
    {
        const int MaxCacheLines = 64;
        List<string> lines = File.Exists(cachePath)
            ? File.ReadAllLines(cachePath).ToList()
            : new List<string>();
        lines.Add(hash + " " + identity);
        if (lines.Count > MaxCacheLines)
            lines.RemoveRange(0, lines.Count - MaxCacheLines);

        File.WriteAllLines(cachePath, lines);
    }

    private (int ExitCode, string StdOut) RunProcessCapture(string exe, string[] args, string workingDir = null,
        bool checkExit = false)
    {
        using Process process = new();
        process.StartInfo.FileName = exe;
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.CreateNoWindow = true;
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;
        process.StartInfo.WorkingDirectory = workingDir ?? Path.GetTempPath();
        foreach (string arg in args)
            process.StartInfo.ArgumentList.Add(arg);

        process.Start();
        string stdout = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        string stderr = process.StandardError.ReadToEnd();
        if (checkExit && process.ExitCode != 0)
            throw new InvalidOperationException(
                $"{exe} failed (exit {process.ExitCode}): {(stderr + stdout).Trim()}");

        return (process.ExitCode, stdout);
    }
}
