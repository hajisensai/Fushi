# flutter_onnxruntime (Hibiki vendored fork)

Vendored from pub.dev `flutter_onnxruntime` **1.8.3**. Referenced via
`dependency_overrides` (`path: ../third_party/flutter_onnxruntime`) in
`fushi/pubspec.yaml`.

## Why vendored

All five native platforms (Android / iOS / Linux / macOS / Windows) are enabled
— Hibiki's built-in manga OCR runs locally on every one of them. The fork keeps
the **Apple deployment floor** at the true `onnxruntime-objc` minimum and makes
the Windows plugin's advertised `DIRECT_ML` provider a real execution path.

Upstream ships a `Package.swift` next to each Apple podspec. When those exist,
Flutter builds the plugin through **Swift Package Manager**, which pulls
`masicai/onnxruntime-swift-package-manager` — and that package's manifest
declares `platforms: [.iOS(.v15), .macOS(.v14)]`. Because Hibiki's macOS Runner
already uses `FlutterGeneratedPluginSwiftPackage`, the macOS 14 floor propagates
to the whole app:

```
error: package 'flutter-onnxruntime' requires minimum platform version 14.0
```

Upstream's podspecs then mirror that with `s.platform = :ios, '16.0'` /
`:osx, '14.0'`. But the **pod** those podspecs actually depend on,
`onnxruntime-objc` 1.23.0, declares only:

| | onnxruntime-objc 1.23.0 | upstream plugin declares | this fork |
|---|---|---|---|
| iOS | 15.1 | 16.0 | **15.1** |
| macOS | 13.4 | 14.0 | **13.4** |

So routing Apple through CocoaPods instead of SwiftPM buys back iOS 15.1–16.0
and macOS 13.4–14.0 for free, with no change to the ORT binary or the Dart API.

## Delta vs upstream 1.8.3

1. Deleted `ios/flutter_onnxruntime/Package.swift` and
   `macos/flutter_onnxruntime/Package.swift`. With no Swift package manifest,
   Flutter falls back to the podspecs on both Apple platforms. The Swift/ObjC++
   sources stay where they are (`<platform>/flutter_onnxruntime/Sources/...`) —
   the podspecs already glob that SPM-shaped layout, so nothing else moves.
2. `ios/flutter_onnxruntime.podspec`: `s.platform = :ios, '16.0'` -> `'15.1'`.
3. `macos/flutter_onnxruntime.podspec`: `s.platform = :osx, '14.0'` -> `'13.4'`.
4. Deleted the `example/` and `doc/` folders (build-irrelevant, reduce vendored
   size).
5. `environment.sdk` widened `^3.7.0` -> `>=3.5.0 <4.0.0` to match the Hibiki
   workspace floor (per the other `third_party/` vendored packages).
6. Windows handles `DIRECT_ML` through ORT's
   `OrtDmlApi::SessionOptionsAppendExecutionProvider_DML` with the required
   sequential execution mode (the upstream generic Windows ORT archive is
   CPU-only, so its Dart enum led only to `INVALID_PROVIDER`). Until delta #13
   the DirectML core (`Microsoft.ML.OnnxRuntime.DirectML` 1.22.0 +
   `Microsoft.AI.DirectML` 1.15.4) was the bundled core; since #13 it is
   downloaded by the app on demand and only `dml_provider_factory.h` is taken
   from that NuGet at build time.
7. Windows error replies are normalised to UTF-8 before they cross the method
   channel (`WindowsUtils::toUtf8Message`, and every `result->Error` in
   `flutter_onnxruntime_plugin.cpp` routed through the single `FailWith` exit).

   Upstream hands `e.what()` to the channel verbatim. ONNX Runtime builds its
   Windows messages by appending the system error text, which `FormatMessage`
   renders in the machine's **ANSI code page** — GBK on a Chinese Windows. The
   channel's string contract is UTF-8 and Dart's decoder is strict, so the reply
   does not merely arrive garbled, it stops being decodable at all: the caller
   gets `FormatException: Unexpected extension byte (at offset N)` and the real
   failure is gone. Measured here: a failing DirectML session produced a
   240-byte message whose 228th byte began `参数错误。` in GBK, which is exactly
   the offset the user saw (BUG-2034).

   Valid UTF-8 is passed through untouched — model paths containing non-ASCII
   are genuine UTF-8 written by ORT's own `ToUTF8String`, and re-decoding those
   as ANSI would corrupt them. The local well-formedness check is deliberately
   at least as strict as Dart's `utf8.decode` (rejects overlong forms, UTF-16
   surrogates and anything past U+10FFFF); anything looser would let a string
   pass here and still blow up on the far side.

8. `windows/flutter_onnxruntime_plugin.cpp` + `lib/src/ort_session.dart`:
   `OrtSessionOptions.freeDimensionOverrides` (`Map<String, int>`) is forwarded
   to ORT's `AddFreeDimensionOverrideByName`.

   The zipformer encoder declares symbolic `N`/`T`, so ORT re-plans the whole
   graph on every `Run` — measured 19k frames/s on a 4070 Ti with DirectML.
   Pinning both dimensions lets ORT fuse the model into a single DML graph:
   129k frames/s at N=32/T=550, outputs identical to the dynamic session to
   within 1e-5. The ORT C++ wrapper shipped with this version does not expose
   the call, hence the raw `Ort::GetApi()` use.

   Windows-only by construction: the other platform plugins never read the key
   and silently ignore it. The Dart-side consumer must therefore gate on the
   execution provider actually in use (`AsrStaticEncoderPool` is created only
   for DirectML), because a session built with the key on a platform that
   ignores it stays dynamic and accepts the static-shaped tensors anyway — it
   is 5-7x slower with no error anywhere.

9. `windows/src/async_dispatch.{h,cc}` (new) + `windows/src/session_manager.*` +
   `windows/flutter_onnxruntime_plugin.cpp`: `runInference`, `createSession`
   and `closeSession` no longer execute inside the method-call handler on the
   platform (UI) thread. Argument parsing and input cloning still happen
   there; the ORT work is posted to one of two `WorkQueue` worker threads —
   sessions created with a GPU provider (DirectML / CUDA) share one queue,
   CPU sessions the other — and the `MethodResult` is completed back on the
   platform thread through `PlatformThreadDispatcher` (a message-only window
   + `PostMessage`). `SessionInfo::session` became a `shared_ptr` so a run in
   flight survives `closeSession`, and `SessionManager::runInference` holds
   the map mutex only for the lookup, not for `Run` itself.

   Two classes of work, one thread each, is deliberate: DirectML crashes when
   two sessions issue `Run` concurrently from two threads in one process
   (reproduced with the Python `onnxruntime-directml` build), while a GPU run
   and a CPU run overlap fine. The audiobook ASR pipeline relies on exactly
   that overlap (GPU encoder ‖ CPU greedy search): 30 min of English went
   from 8.0–8.9 s to 6.1–6.6 s, and the UI thread stopped freezing for the
   duration of every encoder run and every static-shape session build.
   `FLUTTER_ONNXRUNTIME_SYNC=1` in the process environment restores the
   upstream inline behaviour for A/B timing and for isolating threading bugs.

10. `windows/src/dxgi_memory.{h,cc}` (new) + `windows/flutter_onnxruntime_plugin.cpp`
    + `lib/src/onnxruntime.dart` / `flutter_onnxruntime_platform_interface.dart`
    / `flutter_onnxruntime_method_channel.dart` / `lib/flutter_onnxruntime.dart`:
    a `getDeviceMemoryInfo` method returning the DXGI local video-memory
    budget of an adapter (`OrtDeviceMemoryInfo`; `null` on every other platform
    and when DXGI cannot answer). Static-shape DirectML graphs allocate every
    intermediate up front and keep the pool resident per session; a card whose
    budget cannot hold them does not fail — it spills into system memory and
    throughput collapses. The Dart consumer (`asrEncoderBucketsForBudget`)
    sizes its encoder buckets from this number before building any session.

11. `windows/flutter_onnxruntime_plugin.cpp`: CPU sessions no longer share
    the single `cpuQueue_` worker for `runInference` / `closeSession`. Each
    CPU session gets its own `WorkQueue` (created on first use, kept in
    `cpuSessionQueues_`, retired on the platform thread right after the
    close reply), so independent CPU sessions run concurrently while every
    session's own calls stay FIFO. `cpuQueue_` remains for session creation
    (no id yet). GPU sessions still share `gpuQueue_`. The consumer is the
    ASR greedy search: two sessions of the same Loop graph each take half of
    a batch's rows (the Loop graph is frame-sequential and tops out at ~4
    intra-op threads, so one session leaves most cores idle).

    A note on delta #9's "DirectML crashes with two sessions on two threads"
    rationale: that was reproduced with the *Python* `onnxruntime-directml`
    build, whose DML provider factory (`python_api=true` in
    `dml_provider_factory.cc`) deliberately shares one `Dml::ExecutionContext`
    (and thus one command queue) across every session in the process. The
    native C API path this plugin uses creates a separate D3D12 command queue
    and execution context per session, so that reproduction does not carry
    over — concurrent DML sessions are *untested* here, not excluded. It also
    does not matter yet: the 2026-09-07 nvidia-smi measurement showed the
    encoder GPU idle ~85% of the time for lack of queued work, which is what
    the Dart-side pipeline rewrite (`AsrBatchPipeline`) addresses.

**The Dart API under `lib/` carries three deltas (#8, the
`freeDimensionOverrides` option, #10, `getDeviceMemoryInfo`, and #13,
`probeCuda` / `registerCudaRuntime`); everything
else there is byte-for-byte upstream.** The Apple, Android and Linux native
trees are untouched; the Windows tree carries deltas 6–11 and 13 — provider
wiring, error-string encoding, free-dimension overrides, worker-thread
dispatch, the DXGI budget query and per-session CPU workers. No ORT wrapper
or inference logic changed anywhere.

Guards: `fushi/test/ocr/onnxruntime_windows_error_encoding_guard_test.dart`
keeps delta 7 in place,
`fushi/test/onnx/onnxruntime_free_dimension_override_guard_test.dart` keeps
delta 8, `fushi/test/onnx/onnxruntime_async_dispatch_guard_test.dart` keeps
deltas 9 and 11 and `fushi/test/onnx/onnxruntime_device_memory_guard_test.dart`
keeps delta 10 — a re-vendor that drops either half of any of them fails a guard. Delta 8 needs a
guard more than the others do because losing only its C++ half is **silent**:
Dart keeps putting the key in the map, the plugin no longer reads it, the
session falls back to dynamic shapes, and every result stays correct while the
encoder runs 5-7x slower.

## Deployment targets this fork requires

The app projects must stay at or above the podspec floors, or `pod install`
fails outright:

- `fushi/ios/Podfile` — `platform :ios, '15.1'`
- `fushi/ios/Runner.xcodeproj` — `IPHONEOS_DEPLOYMENT_TARGET = 15.1` (3 configs)
- `fushi/macos/Podfile` — `platform :osx, '13.4'`
- `fushi/macos/Runner.xcodeproj` — `MACOSX_DEPLOYMENT_TARGET = 13.4` (3 configs)

Guard: `fushi/test/tools/onnxruntime_apple_gate_guard_test.dart` pins all four
plus the podspec floors, so a re-vendor cannot silently reintroduce the SwiftPM
path or drift the floors apart.

## Re-vendoring on upgrade

Copy the new upstream version over this folder, then re-apply deltas #1–#14.
Before bumping the `onnxruntime-objc` pin, check the new version's podspec
platforms (`pod spec cat onnxruntime-objc --version=X.Y.Z`) — if the floor moved,
the four project deployment targets and the guard test move with it.

12. `linux/CMakeLists.txt`: the downloaded ORT library is bundled as its real
    ELF under the SONAME (`libonnxruntime.so.1`) instead of the unversioned
    `lib/libonnxruntime.so` path. In the ORT tarball that path is a symlink
    chain (`.so` -> `.so.1` -> `.so.1.22.0`); `install(FILES)` copied the first
    link verbatim, so `bundle/lib` held a dangling `libonnxruntime.so` while the
    runner and the plugin both carry `DT_NEEDED libonnxruntime.so.1`. The build
    machine never noticed (the plugin's build RUNPATH points back into the
    build tree), but on any other machine the loader refused to start the whole
    app. The plugin target also gets `$ORIGIN` in its RUNPATH: its own
    `DT_NEEDED libonnxruntime.so.1` is resolved through the plugin's RUNPATH
    (the runner's `$ORIGIN/lib` does not cover transitive dependencies), which
    upstream left as the absolute build-tree path only. Verified with `ldd` on
    a bundle copied into a clean container.

13. Windows runtime split: the **latest CPU core is bundled**; CUDA and
    DirectML are both **downloaded by the app on demand** (`windows/src/
    ort_runtime_loader.{h,cc}` and `cuda_provider.{h,cc}` new,
    `session_manager.*`, `dml_provider.cc`, `flutter_onnxruntime_plugin.*`,
    `CMakeLists.txt`; Dart: `onnxruntime.dart` / platform interface / method
    channel).

    - Bundled: `Microsoft.ML.OnnxRuntime` **1.31.0** (CPU) —
      `onnxruntime.dll` + `onnxruntime_providers_shared.dll`. It is the same ORT
      revision the official CUDA plugin EP v0.3.0 is built against; the plugin
      release notes warn that a core whose contributed-operator schemas differ
      from the plugin's "may execute incorrectly ... may not be detected".
    - DirectML only ships in `Microsoft.ML.OnnxRuntime.DirectML`, whose last
      release is 1.24.4, so it cannot share a core with the CUDA plugin. One
      process can map only one `onnxruntime.dll`. Hence:
      - the plugin links `onnxruntime.dll` with `/DELAYLOAD` and
        `ORT_API_MANUAL_INIT`; nothing touches ORT at registration (the
        `SessionManager` / `TensorManager` are created lazily);
      - `selectRuntime(path)` (`OrtRuntimeLoader::Select`) `LoadLibraryExW`s a
        downloaded DirectML core with `LOAD_WITH_ALTERED_SEARCH_PATH` (its
        `DirectML.dll` resolves from the same folder) **before** ORT is first
        bound; the delay-load helper then binds to the already-mapped module.
        Once bound, only the same path answers ok — switching needs a restart;
      - the first method that needs ORT calls `OrtRuntimeLoader::Ensure`:
        `OrtGetApiBase()` under SEH (a missing DLL is a structured exception
        with delay-load), `GetApi(kOrtApiVersionUsed)` and `Ort::InitApi`.
        Failure is sticky and every such method replies `RUNTIME_UNAVAILABLE`
        instead of crashing the process. `kOrtApiVersionUsed` (22) is the
        oldest API both cores provide; `GetExecutionProviderApi("DML", ...)`
        passes it too;
      - methods that never bind ORT: `getPlatformVersion`, `probeCuda`,
        `getDeviceMemoryInfo` (DXGI only, used to detect a GPU before choosing
        the core), `selectRuntime`, `getRuntimeInfo` (`{loaded, version,
        selectedPath}`).
    - `probeCuda` loads `nvcuda.dll` from System32 only (`cuDriverGetVersion`,
      `cuInit`, `cuDeviceGet*`) and replies `{driverVersion, devices[{index,
      name, computeMajor, computeMinor, totalMemBytes}], error}`. It never
      needs the CUDA runtime, so the app can gate the ~0.9 GB download on driver
      >= 13000 and sm_75+.
    - `registerCudaRuntime(dir)` prepends `dir` to the process `PATH`, then
      `RegisterExecutionProviderLibrary(env, "CUDAExecutionProvider",
      dir\onnxruntime_providers_cuda.dll)` and caches the CUDA `OrtEpDevice`s
      from `GetEpDevices`. PATH is required, not a convenience: cuDNN loads its
      sub-libraries by bare name at run time, which neither `AddDllDirectory`
      nor preloading `cudnn64_9.dll` covers (both measured, Conv then fails
      with `CUDNN_BACKEND_API_FAILED`). Idempotent for the same directory; a
      failure unregisters again and restores PATH; a second directory while
      one is registered is refused. Runs on the GPU worker queue.
    - `provider == "CUDA"` in `createSession` appends the registered device via
      `SessionOptionsAppendExecutionProvider_V2`. Not registered ->
      `PROVIDER_ERROR`, which the Dart fallback reports as a visible downgrade.
      `deviceId` indexes the CUDA EP devices.
    - `getAvailableProviders` merges the EP names `GetEpDevices` reported at
      registration (`GetAvailableProviders` never lists plugin EPs).
    - `SessionManager::~SessionManager` releases every session, then
      `UnregisterExecutionProviderLibrary`, then the env — the only order ORT
      allows. Fushi's own close path is Dart `exit(0)`, which skips plugin
      destructors entirely.

    cuDNN missing or mismatched does not fail session creation — the first
    `Run` fails at Conv. Callers must treat the first run as the health check.
    The download manifests (per-member sizes + SHA-256) and the startup core
    choice live in the app: `fushi/lib/src/asr_host/gpu_runtime_pack.dart` and
    `gpu_acceleration.dart`.

14. Android ORT `1.23.0` -> **`1.28.0`**, and every Android session gets
    `mlas.disable_kleidiai=1` (`android/build.gradle`,
    `FlutterOnnxruntimePlugin.kt` `createSession`; BUG-3636). iOS/macOS stay on
    `onnxruntime-objc` 1.23.0.

    - 1.23.x MLAS picks KleidiAI's **SME2** kernels whenever the CPU reports
      SME. Snapdragon 8 Elite Gen 5 (Oryon) has SME but not SME2, so
      `OrtSession.run` died with SIGILL ILL_ILLOPC. Measured on the release
      aar (BuildId `34a68042…`): the crash PC is `whilelt pn8.h, x11, x24,
      vlx2` right after `smstart` — predicate-as-counter is SME2-only. The
      1.23.0 binary ships only `_sme2_mopa` f32 matmul kernels; 1.28.0 ships
      `_sme_mopa` and `_sme2_mopa` variants and dispatches between them
      (microsoft/onnxruntime#26377, fixed by #27403).
    - 1.28.0, not newer: sherpa-onnx measured 1.27.0 miscomputing on the same
      SoC with 1.28.0 correct, and from 1.29 the official Android package sends
      telemetry by default (#27379 / #29872). Upstream plugin PR #79 picked
      1.28.0 for the same reason.
    - KleidiAI stays off on Android even after the upgrade: it only engages on
      SME phones, and there it still keeps per-thread MatMul buffers sized for
      the largest input shape and never returns them (#29538, reproduced on
      1.28.0 at GB scale; OCR inputs are dynamic-shape). The key exists from
      ORT 1.25. Every Android device therefore runs the same NEON MLAS path
      non-SME phones always ran. Remove the entry only once #29538 is fixed and
      KleidiAI is verified on an SME-only device.
    - Same 12 JNI `FindClass` descriptors and still `classes.jar`-only (no
      consumer ProGuard rules) — `fushi/android/app/proguard-rules.pro` keeps
      them unchanged. Guard: `fushi/test/ocr/onnxruntime_android_kleidiai_guard_test.dart`.

15. `lib/src/ort_provider.dart` + `lib/src/onnxruntime.dart`:
    `getAvailableProviders()` no longer throws on a provider name the Dart enum
    does not know (feedback eEnV5gBn1K).

    - Upstream matched native names against `OrtProvider.name` exactly and threw
      `ArgumentError('Provider X is not a valid OrtProvider.')` otherwise. Android
      passes the Java `OrtProvider` enum name through, and since delta #14 the
      1.28.0 aar's Java enum contains `WEBGPU` (`javap` on
      `ai/onnxruntime/OrtProvider.class`: CPU, CUDA, DNNL, OPEN_VINO, VITIS_AI,
      TENSOR_RT, NNAPI, RK_NPU, DIRECT_ML, MI_GRAPH_X, ACL, ROCM, CORE_ML,
      XNNPACK, AZURE, QNN, WEBGPU). The Dart spelling is `WEB_GPU`, so every
      Android probe failed and the ASR sheet showed the raw `ArgumentError`.
    - The Dart enum gains the Java names upstream lacked (`MI_GRAPH_X`,
      `RK_NPU`, `VITIS_AI`). `ortProviderFromNativeName` is the one normaliser:
      exact enum name, then aliases for every spelling a native side reports —
      Java `WEBGPU`, the Windows/Linux tables' `MIGRAPHX`, and raw ORT C names
      (`XxxExecutionProvider`), which Windows/Linux/Apple pass through when
      unmapped. Native code is unchanged.
    - A name with no `OrtProvider` value is left out of the list and logged
      under `flutter_onnxruntime`: it cannot be requested through
      `OrtSessionOptions.providers` anyway, so it is correctly absent from the
      "providers you can request" result rather than an error of the probe.
    - Test: `fushi/test/onnx/onnxruntime_provider_names_test.dart` (through the
      real method channel).

Before bumping the bundled Windows core, bump the CUDA plugin EP to the release
built against the same ORT revision (and its manifest in
`gpu_runtime_pack.dart`), update the nupkg SHA-256, and keep both runtime DLLs
in `flutter_onnxruntime_bundled_libraries`. `kOrtApiVersionUsed` must stay at
or below the API version of the downloaded DirectML core.
