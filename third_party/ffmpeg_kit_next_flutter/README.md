# FFmpegKitNext for Flutter

### 1. Features

- Includes both `FFmpeg` and `FFprobe`
- Supports
    - `Android`, `iOS`, `iPadOS`, `macOS` and `Linux`
    - `arm-v7a`, `arm-v7a-neon`, `arm64-v8a`, `x86` and `x86_64` architectures on Android
    - `Android API Level 24` or later
    - `armv7`, `armv7s`, `arm64`, `arm64-simulator`, `i386`, `x86_64`, `x86_64-mac-catalyst` and `arm64-mac-catalyst`
      architectures on iOS
    - `iOS 12.1+` deployment targets
    - iPad devices and the iPad Simulator load `iOS` frameworks/xcframeworks
    - `arm64` and `x86_64` architectures on macOS
    - `macOS 10.15+` deployment targets
    - `x86_64` and `arm64` architectures on Linux
    - Can process Storage Access Framework (SAF) Uris on Android
    - 25 external libraries

      `dav1d`, `fontconfig`, `freetype`, `fribidi`, `gmp`, `gnutls`, `kvazaar`, `lame`, `libass`, `libiconv`, `libilbc`
      , `libtheora`, `libvorbis`, `libvpx`, `libwebp`, `libxml2`, `opencore-amr`, `opus`, `shine`, `snappy`, `soxr`
      , `speex`, `twolame`, `vo-amrwbenc`, `zimg`

    - 4 external libraries with GPL license

      `vid.stab`, `x264`, `x265`, `xvidcore`

- Licensed under `LGPL 3.0` by default, `GPL v3.0` if GPL licensed libraries are enabled

### 2. Installation

`ffmpeg_kit_next_flutter` is not published to `pub.dev`. Build `FFmpegKitNext` locally for the native platforms you
target, then integrate the Flutter plugin from this repository using a local path dependency.

> **Building the native binaries:** see [BUILD.md](BUILD.md) for the one-time setup that builds `FFmpegKitNext`
> from source and copies the native binaries into this plugin before you use it.

```yaml
dependencies:
  ffmpeg_kit_next_flutter:
    path: ../ffmpeg-kit-next/flutter/flutter
```

Adjust the path to match where this repository is located relative to your Flutter application.

Do not add `ffmpeg_kit_next_flutter` as a hosted dependency. The plugin and the native binaries are expected to come
from your local build.

**Android requires one extra step.** The plugin's native AAR is served from a local Maven repository bundled inside
the plugin (`android/libs-maven`). Because Gradle does not inherit a dependency's repositories, your app must declare
that repository too, or it will fail to resolve `com.arthenica:ffmpeg-kit-next` while building the APK. Add a
**project-level** repository to your app's `android/build.gradle`:

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

The path is derived from the plugin Flutter already resolved, so the same snippet works for any app. Keep it in
`build.gradle`, not in `settings.gradle`'s `dependencyResolutionManagement` (that breaks Flutter's engine resolution —
see [BUILD.md](BUILD.md)). iOS, iPadOS and macOS need no extra repository step.

#### 2.1 Build Variants and External Libraries

`FFmpeg` includes built-in encoders for some popular formats. Some formats/codecs require external libraries to be
enabled in the native build. For example, `mp3` encoding needs `lame` or `shine`, `h264` needs `x264`, and `vp8`/`vp9`
needs `libvpx`.

Those libraries are selected when you build `FFmpegKitNext` locally with the Nix wrapper build scripts. There are no
separate `pub.dev` packages such as `min`, `https`, `audio`, `video`, `full`, or `full-gpl` to install.

#### 2.2 Platform Support

The following table shows Android API level, iOS/iPadOS deployment target and macOS deployment target requirements in
`ffmpeg_kit_next_flutter`.

<table>
<thead>
<tr>
<th align="center">Android<br>API Level</th>
<th align="center">iOS/iPadOS Minimum<br>Deployment Target</th>
<th align="center">macOS Minimum<br>Deployment Target</th>
</tr>
</thead>
<tbody>
<tr>
<td align="center">24</td>
<td align="center">12.1</td>
<td align="center">10.15</td>
</tr>
</tbody>
</table>

### 3. Using

1. Execute FFmpeg commands.

    ```dart
    import 'package:ffmpeg_kit_next_flutter/ffmpeg_kit.dart';

    FFmpegKit.execute('-i file1.mp4 -c:v mpeg4 file2.mp4').then((session) async {
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {

        // SUCCESS

      } else if (ReturnCode.isCancel(returnCode)) {

        // CANCEL

      } else {

        // ERROR

      }
    });
    ```

2. Each `execute` call creates a new session. Access every detail about your execution from the session created.

    ```dart
    FFmpegKit.execute('-i file1.mp4 -c:v mpeg4 file2.mp4').then((session) async {

      // Unique session id created for this execution
      final sessionId = session.getSessionId();

      // Command arguments as a single string
      final command = session.getCommand();

      // Command arguments
      final commandArguments = session.getArguments();

      // State of the execution. Shows whether it is still running or completed
      final state = await session.getState();

      // Return code for completed sessions. Will be undefined if session is still running or FFmpegKit fails to run it
      final returnCode = await session.getReturnCode();

      final startTime = session.getStartTime();
      final endTime = await session.getEndTime();
      final duration = await session.getDuration();

      // Console output generated for this execution
      final output = await session.getOutput();

      // The stack trace if FFmpegKit fails to run a command
      final failStackTrace = await session.getFailStackTrace();

      // The list of logs generated for this execution
      final logs = await session.getLogs();

      // The list of statistics generated for this execution (only available on FFmpegSession)
      final statistics = await (session as FFmpegSession).getStatistics();

    });
    ```

3. Execute `FFmpeg` commands by providing session specific `execute`/`log`/`session` callbacks.

    ```dart
    FFmpegKit.executeAsync('-i file1.mp4 -c:v mpeg4 file2.mp4', (Session session) async {

      // CALLED WHEN SESSION IS EXECUTED

    }, (Log log) {

      // CALLED WHEN SESSION PRINTS LOGS

    }, (Statistics statistics) {

      // CALLED WHEN SESSION GENERATES STATISTICS

    });
    ```

4. Execute `FFprobe` commands.

    ```dart
    FFprobeKit.execute(ffprobeCommand).then((session) async {

      // CALLED WHEN SESSION IS EXECUTED

    });
    ```

5. Get media information for a file/url.

    ```dart
    FFprobeKit.getMediaInformation('<file path or url>').then((session) async {
      final information = await session.getMediaInformation();

      if (information == null) {

        // CHECK THE FOLLOWING ATTRIBUTES ON ERROR
        final state = FFmpegKitConfig.sessionStateToString(await session.getState());
        final returnCode = await session.getReturnCode();
        final failStackTrace = await session.getFailStackTrace();
        final duration = await session.getDuration();
        final output = await session.getOutput();
      }
    });
    ```

6. Stop ongoing FFmpeg operations.

- Stop all sessions
  ```dart
  FFmpegKit.cancel();
  ```
- Stop a specific session
  ```dart
  FFmpegKit.cancel(sessionId);
  ```

7. (Android) Convert Storage Access Framework (SAF) Uris into paths that can be read or written by
   `FFmpegKit` and `FFprobeKit`.

- Reading a file:
  ```dart
  FFmpegKitConfig.selectDocumentForRead('*/*').then((uri) {
    // By default a saf url can be used only once and is released automatically
    // when the execution completes. Pass the optional reusable flag to use the
    // same url in more than one command and release it manually afterwards.
    FFmpegKitConfig.getSafParameterForRead(uri!, true).then((safUrl) {
      FFmpegKit.executeAsync("-i ${safUrl!} -c:v mpeg4 file2.mp4").then((_) {
        FFmpegKitConfig.unregisterSafProtocolUrl(safUrl);
      });
    });
  });
  ```

- Writing to a file:
  ```dart
  FFmpegKitConfig.selectDocumentForWrite('video.mp4', 'video/*').then((uri) {
    FFmpegKitConfig.getSafParameterForWrite(uri!).then((safUrl) {
      FFmpegKit.executeAsync("-i file1.mp4 -c:v mpeg4 ${safUrl}");
    });
  });
  ```

8. Get previous `FFmpeg`, `FFprobe` and `MediaInformation` sessions from the session history.

    ```dart
    FFmpegKit.listSessions().then((sessionList) {
      sessionList.forEach((session) {
        final sessionId = session.getSessionId();
      });
    });

    FFprobeKit.listFFprobeSessions().then((sessionList) {
      sessionList.forEach((session) {
        final sessionId = session.getSessionId();
      });
    });

    FFprobeKit.listMediaInformationSessions().then((sessionList) {
      sessionList.forEach((session) {
        final sessionId = session.getSessionId();
      });
    });
    ```

9. Enable global callbacks.

- Session type specific Complete Callbacks, called when an async session has been completed

  ```dart
  FFmpegKitConfig.enableFFmpegSessionCompleteCallback((session) {
    final sessionId = session.getSessionId();
  });

  FFmpegKitConfig.enableFFprobeSessionCompleteCallback((session) {
    final sessionId = session.getSessionId();
  });

  FFmpegKitConfig.enableMediaInformationSessionCompleteCallback((session) {
    final sessionId = session.getSessionId();
  });
  ```

- Log Callback, called when a session generates logs

  ```dart
  FFmpegKitConfig.enableLogCallback((log) {
    final message = log.getMessage();
  });
  ```

- Statistics Callback, called when a session generates statistics

  ```dart
  FFmpegKitConfig.enableStatisticsCallback((statistics) {
    final size = statistics.getSize();
  });
  ```

10. Register system fonts and custom font directories.

    ```dart
    FFmpegKitConfig.setFontDirectoryList(["/system/fonts", "/System/Library/Fonts", "<folder with fonts>"]);
    ```

11. (Android) Get the camera ids supported by the native camera input.

    ```dart
    FFmpegKitConfig.getSupportedCameraIds().then((cameraIds) {
      cameraIds.forEach((cameraId) {
        print("Camera id: $cameraId");
      });
    });
    ```

12. Use the Flutter API from an isolate.

    ```dart
    import 'package:flutter/services.dart';

    Future<void> ffmpegWorker(RootIsolateToken rootIsolateToken) async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
      await FFmpegKitConfig.init(printLoadConfirmation: false);

      final session = await FFmpegKit.execute('-version');
      final output = await session.getOutput();
    }
    ```

### 4. Test Application

You can see how `FFmpegKitNext` is used inside an application by running `flutter` test applications developed under
the [FFmpegKitNext Test](https://github.com/arthenica/ffmpeg-kit-next-test) project.

### 5. Tips

See [Tips](https://github.com/arthenica/ffmpeg-kit-next/wiki/Tips) wiki page.

### 6. License

See [License](https://github.com/arthenica/ffmpeg-kit-next/wiki/License) wiki page.

### 7. Patents

See [Patents](https://github.com/arthenica/ffmpeg-kit-next/wiki/Patents) wiki page.
