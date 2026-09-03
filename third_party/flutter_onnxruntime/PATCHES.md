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
6. Windows downloads the pinned official
   `Microsoft.ML.OnnxRuntime.DirectML` 1.22.0 and `Microsoft.AI.DirectML`
   1.15.4 NuGet artifacts (SHA-256 pinned), bundles `onnxruntime.dll`,
   `onnxruntime_providers_shared.dll`, and `DirectML.dll`, and handles
   `DIRECT_ML` through ORT's
   `OrtDmlApi::SessionOptionsAppendExecutionProvider_DML` with the required
   sequential execution mode. The upstream generic Windows ORT archive is
   CPU-only, so its Dart enum previously led only to `INVALID_PROVIDER`.
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

**The Dart API under `lib/` is byte-for-byte upstream.** The Apple, Android and
Linux native trees are untouched as well; the Windows tree carries deltas 6 and
7 above, both confined to provider wiring and error-string encoding — no ORT
wrapper or inference logic changed anywhere.

Guard: `fushi/test/ocr/onnxruntime_windows_error_encoding_guard_test.dart` keeps
delta 7 in place — a re-vendor that drops it, or a new error branch that calls
`result->Error` directly, fails the guard.

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

Copy the new upstream version over this folder, then re-apply deltas #1–#6.
Before bumping the `onnxruntime-objc` pin, check the new version's podspec
platforms (`pod spec cat onnxruntime-objc --version=X.Y.Z`) — if the floor moved,
the four project deployment targets and the guard test move with it.

Before bumping the Windows ORT pin, update both NuGet package versions and
SHA-256 values together, verify the DirectML package's declared
`Microsoft.AI.DirectML` dependency, and keep all three runtime DLLs in
`flutter_onnxruntime_bundled_libraries`.
