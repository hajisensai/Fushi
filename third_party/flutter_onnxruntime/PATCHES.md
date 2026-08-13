# flutter_onnxruntime (Hibiki vendored fork)

Vendored from pub.dev `flutter_onnxruntime` **1.8.3**. Referenced via
`dependency_overrides` (`path: ../third_party/flutter_onnxruntime`) in
`fushi/pubspec.yaml`.

## Why vendored

All five native platforms (Android / iOS / Linux / macOS / Windows) are enabled
— Hibiki's built-in manga OCR runs locally on every one of them. The fork exists
only to keep the **Apple deployment floor** at the true `onnxruntime-objc`
minimum instead of upstream's conservative declaration.

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

**The Dart API under `lib/` is byte-for-byte upstream**, and so are all five
native source trees — no ORT wrapper logic changed anywhere.

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

Copy the new upstream version over this folder, then re-apply deltas #1–#5.
Before bumping the `onnxruntime-objc` pin, check the new version's podspec
platforms (`pod spec cat onnxruntime-objc --version=X.Y.Z`) — if the floor moved,
the four project deployment targets and the guard test move with it.
