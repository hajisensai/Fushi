# receive_intent 0.2.3 (arianneorpilla fork) — vendored

Upstream: https://github.com/arianneorpilla/receive_intent at
`3854d07f8f4e9d5a78589639b18b5d454ddf54a0` ("Custom changes for handling
Jellyfin intent"), a fork of https://github.com/daadu/receive_intent 0.2.3.
Was a `git:` dependency in `fushi/pubspec.yaml`; vendored and pointed at by the
workspace `pubspec.yaml` dependency_overrides so the Gradle delta below is
tracked source. Only the plugin itself is copied (`android/`, `lib/`, pubspec,
license, README, CHANGELOG); the upstream example app and tests are not.

## Deltas vs the fork commit

1. Flutter 3.50 / Gradle 9 / AGP 9 (`android/build.gradle`): Gradle 9 removed
   `RepositoryHandler.jcenter()`, so the upstream script failed while the app
   evaluated the plugin subproject (`Could not find method jcenter()`). The
   buildscript now uses `google()` + `mavenCentral()`, the
   `rootProject.allprojects { repositories { ... jcenter() } }` block is dropped
   (the app's root `build.gradle` already declares every repository), the
   buildscript pins follow the app (AGP 9.3.1, Kotlin 2.4.20 since BUG-5148), and the library
   declares `namespace 'com.bhikadia.receive_intent'` itself instead of relying
   on the app's manifest-package fallback. `compileSdk` is set to 34, which the
   app's root `build.gradle` forces for plugin subprojects anyway.
