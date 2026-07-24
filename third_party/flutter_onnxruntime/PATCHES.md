# flutter_onnxruntime (Hibiki vendored fork)

Vendored from pub.dev `flutter_onnxruntime` **1.8.3**. Referenced via
`dependency_overrides` (`path: ../third_party/flutter_onnxruntime`) in
`hibiki/pubspec.yaml`.

## Why vendored

Upstream declares `ios` and `macos` under `flutter.plugin.platforms`, and its
Apple podspecs (`ios/flutter_onnxruntime.podspec`,
`macos/flutter_onnxruntime.podspec`) pin **`onnxruntime-objc` 1.23.0**, which
forces the deployment target to **macOS 14.0 / iOS 16.0**. Because it is a
federated MethodChannel plugin declaring `macos`, Flutter registers it into the
macOS Swift Package (`FlutterGeneratedPluginSwiftPackage`), which then fails the
whole macOS build:

```
error: package 'flutter-onnxruntime' requires minimum platform version 14.0
```

Hibiki's project targets **macOS 10.15** and a lower iOS deployment target
(`hibiki/macos/Podfile` + `Runner.xcodeproj`), and must not drop older Apple
users (Never break userspace). Hibiki's built-in ONNX manga OCR is only wired
for **Windows / Linux / Android** anyway — on Apple the manga reader degrades to
the interconnect-host OCR or the Gemini cloud OCR path (see
`hibiki/lib/src/ocr/ocr_inference_ort.dart` `isLocalOnnxRuntimeAvailable`).

## Delta vs upstream 1.8.3

1. `pubspec.yaml`: removed the `ios` and `macos` entries from
   `flutter.plugin.platforms`. Kept `android`, `linux`, `web`, `windows`. With
   no `macos`/`ios` declaration, Flutter never adds the plugin to the Apple
   native build, so the deployment target stays at 10.15 / the project's iOS
   floor.
2. Deleted the `ios/` and `macos/` native source trees (belt-and-suspenders;
   they are unreferenced once the platform declarations are gone) plus the
   `example/` and `doc/` folders (build-irrelevant, reduce vendored size).
3. `environment.sdk` widened `^3.7.0` -> `>=3.5.0 <4.0.0` to match the Hibiki
   workspace floor (per the other `third_party/` vendored packages).

**The Dart API under `lib/` is byte-for-byte upstream** — no ORT wrapper logic
changed. `onnxruntime` native for Android/Windows/Linux is untouched, so OCR on
those platforms works exactly as before.

## Re-vendoring on upgrade

Copy the new upstream version over this folder, then re-apply delta #1 (drop
`ios`/`macos` from plugin platforms), #2 (delete `ios/ macos/ example/ doc/`),
and #3 (SDK bound). Only bump the Apple support back if the project's macOS
deployment target is raised to >= 14.0 and iOS to >= 16.0 first.
