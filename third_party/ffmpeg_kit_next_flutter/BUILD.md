# Using this plugin with locally-built native binaries

This plugin is **not** published to pub.dev and does **not** download native
binaries from any remote repository (Maven Central / CocoaPods trunk). Instead
the FFmpegKitNext native binaries are built from source and copied into the
plugin's own platform folders, so the package is self-contained and consumed
via a local path dependency.

## One-time setup (per machine / CI)

From the repository root, build the native binaries for the platforms you need
with the desired external libraries:

```bash
./nix-android.sh -p <profile>   # produces prebuilt/bundle-android-aar-*-maven/...
./nix-ios.sh     -p <profile>   # produces prebuilt/bundle-apple-xcframework-ios-*/... (covers both iOS and iPadOS)
./nix-macos.sh   -p <profile>   # produces prebuilt/bundle-apple-xcframework-macos-*/...
./nix-linux.sh   -p <profile>   # produces prebuilt/bundle-linux/... (native host architecture only)
```

Then copy the built artifacts into this plugin:

```bash
cd flutter/flutter
./copy_local_binaries.sh            # all available platforms
# or copy selectively:
./copy_local_binaries.sh android ios
./copy_local_binaries.sh linux
```

This places:

| Platform | Destination (git-ignored)                                | Referenced by                       |
|----------|----------------------------------------------------------|-------------------------------------|
| Android  | `android/libs-maven/` (local Maven repository)           | `android/build.gradle`              |
| iOS/iPadOS     | `ios/ffmpeg_kit_next_flutter/Frameworks/*.xcframework`   | `ios/*.podspec` + `Package.swift`   |
| macOS    | `macos/ffmpeg_kit_next_flutter/Frameworks/*.xcframework` | `macos/*.podspec` + `Package.swift` |
| Linux    | `linux/Frameworks/ffmpeg-kit-next/{include,lib}`         | `linux/CMakeLists.txt`              |

The copied binaries are ignored by git on purpose — every consumer rebuilds and
copies them. Re-run `copy_local_binaries.sh` whenever you rebuild.

On Android the copy is a small local Maven repository at
`android/libs-maven/com/arthenica/ffmpeg-kit-next/<version>/` (e.g.
`ffmpeg-kit-next-6.1.2.aar` plus its `.pom`). `android/build.gradle` consumes it via
`maven { url "$projectDir/libs-maven" }` and depends on it by Maven coordinate
`implementation 'com.arthenica:ffmpeg-kit-next:<version>'` (no longer the
`flatDir` + `implementation(name: 'ffmpeg-kit-next', ext: 'aar')` form).

The Apple plugins ship both a CocoaPods podspec and a Swift Package Manager
`Package.swift` (under `<platform>/ffmpeg_kit_next_flutter/`). Flutter uses the
Swift package when Swift Package Manager is enabled and falls back to the podspec
otherwise; both reference the same `Sources/` and `Frameworks/` trees.

## Consuming the plugin from an app

In the app's `pubspec.yaml`, reference the plugin by path:

```yaml
dependencies:
  ffmpeg_kit_flutter:
    path: /path/to/ffmpeg-kit-next/flutter/flutter
```

The plugin depends on `ffmpeg_kit_next_flutter_platform_interface` (pure Dart, no
native code). It resolves from pub.dev by default; to use the local copy too,
add an override:

```yaml
dependency_overrides:
  ffmpeg_kit_next_flutter_platform_interface:
    path: /path/to/ffmpeg-kit-next/flutter/flutter_platform_interface
```

### Android: register the bundled Maven repository

The plugin's Android AAR is served from the local Maven repository copied into
`android/libs-maven` (see the table above). Gradle does **not** inherit a
dependency's repositories, so the **consuming app** must declare that repository
too — otherwise the app fails to resolve `com.arthenica:ffmpeg-kit-next:<version>`
while packaging the APK.

Add it to the app's `android/build.gradle` as a **project-level** repository.
Derive the path from the Gradle project Flutter already includes for the plugin,
so you never hardcode a path into the plugin's source tree:

```groovy
allprojects {
    repositories {
        google()
        mavenCentral()
        def ffmpegKitProject = rootProject.findProject(":ffmpeg_kit_next_flutter")
        if (ffmpegKitProject != null) {
            maven {
                url "${ffmpegKitProject.projectDir}/libs-maven"
            }
        }
    }
}
```

`ffmpegKitProject.projectDir` is the plugin's `android/` folder wherever Flutter
resolved the dependency (local path, pub cache, …), so the same snippet works for
any consumer without editing.

Keep this in `build.gradle` (project-level). Do **not** move it into
`settings.gradle`'s `dependencyResolutionManagement` with
`RepositoriesMode.PREFER_SETTINGS`: that mode suppresses Flutter's own
project-level engine repository and breaks `io.flutter:*` resolution. iOS,
iPadOS and macOS need no extra repository step — their frameworks are vendored
via the podspec / Swift package.

## Notes / caveats

- **ABIs / archs are whatever you built.** The Android AAR contains only the
  ABIs compiled by your nix profile, and the Apple xcframeworks only the
  built slices. If the AAR lacks an ABI your build targets (e.g. `x86_64` for an
  emulator), restrict the app with `ndk { abiFilters ... }` or build that ABI.
- **`smart-exception-java` is still fetched from Maven Central.** It is a small
  pure-Java dependency of the AAR (not a native binary), declared in the AAR's POM
  inside `android/libs-maven` and resolved transitively (`android/build.gradle`
  keeps `mavenCentral()` for this). If you must avoid Maven entirely, vendor it as
  a local jar instead.
- **External libraries are fixed by what you enabled.** They are determined by
  the flags passed to `nix-<platform>.sh`.