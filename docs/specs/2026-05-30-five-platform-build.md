# 五平台构建打通 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Hibiki 在全部 5 个发布目标（Android / iOS / macOS / Windows / Linux）都能构建通过，并把"现在五平台全是目标"才暴露的功能缺口收敛到一致状态。

**Architecture:** 单一根因 `record_mp3_plus`（仅 Android/iOS/macOS、iOS 真机-only 静态库、macOS 11.0 部署底）同时压垮 iOS+macOS CI；按用户决策**换成 `record`(llfbandit)** 做真正的全平台录音（输出 mp3→m4a）。在此基础上补齐各平台 ship 必需的配置（Android 录音权限、iOS 身份与麦克风用途、macOS 沙盒联网/麦克风权限、Linux 字典 .so 接入构建 + 阅读器在 Linux 明确标注暂不支持）。签名发布按用户决策**暂不做**，CI 只做免费编译验证（iOS 走 `--no-codesign` 真机编译）。

**Tech Stack:** Flutter 3.41.6 / Dart 3.11.4；`record` ^最新（替换 `record_mp3_plus`）；CMake（Linux runner + native/hoshidicts）；GitHub Actions（build-multiplatform.yml）。

**关键约束（来自 CLAUDE.md / 项目记忆）：**
- develop 上有并发 worker 在同一工作树提交：**只 stage 自己本轮的文件，禁止 `git add -A`**。
- **禁止触碰** `packages/hibiki_platform/lib/src/services/platform_directory_service.dart`（队友 picker 重构 WIP，未提交即修好了 HEAD 的编译错）。Linux 全绿依赖他们提交此文件。
- 代码审查 spawn subagent 必须 `model: "opus"`。
- i18n 新增 key 必须用 `hibiki/tool/i18n_sync.dart`，禁止手改 17 个 json。
- 函数要类型签名；不掩盖症状做根因修复。

---

## File Structure（改动文件清单）

| 文件 | 责任 | 改动 |
|------|------|------|
| `hibiki/pubspec.yaml` | 依赖声明 | 删 `record_mp3_plus`，加 `record` |
| `hibiki/lib/src/pages/implementations/audio_recorder_page.dart` | 录音对话框 | `RecordMp3` → `AudioRecorder` |
| `hibiki/lib/src/creator/enhancements/audio_recorder_enhancement.dart` | 录音增强入口 | 跨平台可用 + `.m4a` + 权限改走 record |
| `hibiki/android/app/src/main/AndroidManifest.xml` | Android 权限 | 加 `RECORD_AUDIO` |
| `hibiki/ios/Runner/Info.plist` | iOS 配置 | 加 `NSMicrophoneUsageDescription` + 显示名 jidoujisho→Hibiki |
| `hibiki/ios/Runner.xcodeproj/project.pbxproj` | iOS 工程 | bundle id → app.hibiki.reader；部署底 11.0→12.0 |
| `hibiki/ios/Flutter/AppFrameworkInfo.plist` | iOS 框架底 | MinimumOSVersion 11.0→12.0 |
| `hibiki/ios/Podfile` | iOS pod | 显式 `platform :ios, '12.0'` |
| `hibiki/macos/Runner/Info.plist` | macOS 配置 | 加 `NSMicrophoneUsageDescription` |
| `hibiki/macos/Runner/Release.entitlements` | macOS 发布权限 | 加 network.client/server + audio-input |
| `hibiki/macos/Runner/DebugProfile.entitlements` | macOS 调试权限 | 加 network.client + audio-input |
| `hibiki/linux/CMakeLists.txt` | Linux 构建 | 接入 native/hoshidicts 构建 + 安装 .so |
| `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` | 阅读器 | `_buildWebView()` Linux 返回"暂不支持"占位 |
| `.github/workflows/build-multiplatform.yml` | CI | iOS `--simulator`→`--no-codesign` |
| `ci/patches/hosted/record_mp3_plus-1.2.0/` | 死补丁 | 删除整目录 |
| `hibiki/i18n/*.i18n.json`(via 脚本) | i18n | 新增 `reader_unsupported_platform` key |

---

## Task 1: 替换依赖 record_mp3_plus → record

**Files:**
- Modify: `hibiki/pubspec.yaml:102`

- [ ] **Step 1: 删除 record_mp3_plus，加入 record**

编辑 `hibiki/pubspec.yaml`，把第 102 行：
```yaml
  record_mp3_plus: ^1.2.0
```
替换为：
```yaml
  record: ^6.0.0
```
（`record` 是 llfbandit 的跨平台录音插件，支持 Android(minSdk23)/iOS12+/macOS/Windows/Linux。版本用 `flutter pub add record` 解析到的最新 caret 即可，下一步用脚本添加避免手写错版本号。）

- [ ] **Step 2: 用 pub add 解析真实版本并 pub get**

Run:
```bash
cd hibiki
D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat pub remove record_mp3_plus
D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat pub add record
```
Expected: `record` 出现在 pubspec.yaml，`pubspec.lock` 解析出具体版本；`record_mp3_plus` 从 lock 消失；各平台 `GeneratedPluginRegistrant` 重新生成不再含 `RecordMp3Plugin`。

- [ ] **Step 3: 确认插件平台注册已更新**

Run:
```bash
grep -rn "RecordMp3Plugin\|record_mp3_plus" hibiki/ios hibiki/macos hibiki/android hibiki/windows hibiki/linux 2>/dev/null || echo "clean"
```
Expected: `clean`（或仅剩注释）；不再有 record_mp3_plus 的 registrant 行。

- [ ] **Step 4: Commit**

```bash
git add hibiki/pubspec.yaml hibiki/pubspec.lock
git commit -m "build(audio): swap record_mp3_plus for cross-platform record plugin"
```

---

## Task 2: 录音对话框迁移到 AudioRecorder API

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/audio_recorder_page.dart:10,379-403`

- [ ] **Step 1: 替换 import**

把第 10 行：
```dart
// ignore: depend_on_referenced_packages
import 'package:record_mp3_plus/record_mp3_plus.dart';
```
替换为：
```dart
import 'package:record/record.dart';
```

- [ ] **Step 2: 新增 AudioRecorder 实例字段**

在 `_AudioRecorderDialogPageState` 类体内（`File? _audioFile;` 上方，约第 37 行）加入：
```dart
  final AudioRecorder _recorder = AudioRecorder();
```

- [ ] **Step 3: dispose 时释放 recorder**

在 `dispose()` 内（约第 47-57 行）`_audioPlayer.dispose();` 之后加入：
```dart
    _recorder.dispose();
```

- [ ] **Step 4: 改写停止按钮（异步 stop）**

把 `buildStopButton()` 的 `onPressed`（约第 378-386 行）：
```dart
      onPressed: () {
        RecordMp3.instance.stop();
        _audioFile = File(widget.filePath);

        initialiseAudio(_audioFile!);
        setState(() {
          _isRecording = false;
        });
      },
```
替换为：
```dart
      onPressed: () async {
        await _recorder.stop();
        _audioFile = File(widget.filePath);

        await initialiseAudio(_audioFile!);
        if (!mounted) return;
        setState(() {
          _isRecording = false;
        });
      },
```

- [ ] **Step 5: 改写录音按钮（权限 + start + try/catch）**

把 `buildRecordButton()` 的 `onPressed`（约第 394-404 行）：
```dart
      onPressed: () async {
        await _audioPlayer.stop();
        setState(() {
          _isRecording = true;
        });
        RecordMp3.instance.start(widget.filePath, (error) {
          setState(() {
            _isRecording = false;
          });
        });
      },
```
替换为：
```dart
      onPressed: () async {
        await _audioPlayer.stop();
        if (!await _recorder.hasPermission()) {
          HibikiToast.show(msg: t.no_audio_file);
          return;
        }
        if (!mounted) return;
        setState(() {
          _isRecording = true;
        });
        try {
          await _recorder.start(
            const RecordConfig(encoder: AudioEncoder.aacLc),
            path: widget.filePath,
          );
        } on Exception {
          if (!mounted) return;
          setState(() {
            _isRecording = false;
          });
        }
      },
```
（注：`record` 无 mp3 编码器，用 AAC-LC 输出 `.m4a`；just_audio 能正常播放 m4a，Anki 媒体也接受 m4a。权限不足时用现有 `t.no_audio_file` 文案提示并中止。）

- [ ] **Step 6: 分析通过**

Run:
```bash
cd hibiki
D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/pages/implementations/audio_recorder_page.dart
```
Expected: No issues found.

- [ ] **Step 7: Commit**

```bash
git add hibiki/lib/src/pages/implementations/audio_recorder_page.dart
git commit -m "refactor(audio): migrate recorder dialog to record AudioRecorder API"
```

---

## Task 3: 录音增强入口跨平台化 + 输出 .m4a

**Files:**
- Modify: `hibiki/lib/src/creator/enhancements/audio_recorder_enhancement.dart:7,30,44,62,82`

- [ ] **Step 1: 移除 permission_handler import**

删除第 7 行：
```dart
import 'package:permission_handler/permission_handler.dart';
```
（权限改由对话框内 `record.hasPermission()` 处理，更贴近使用点。）

- [ ] **Step 2: isAvailable 改为全平台**

把第 30 行：
```dart
  static bool get isAvailable => isAndroidPlatform;
```
替换为：
```dart
  // record 插件支持 Android/iOS/macOS/Windows/Linux；Linux 需系统具备
  // parecord/pactl/ffmpeg 才能实际编码，否则录音在运行时报错并回退。
  static bool get isAvailable => true;
```

- [ ] **Step 3: 去掉 Android-only 早退 + 内联权限分支，输出 .m4a**

把 `enhanceCreatorParams` 方法体（第 44-102 行，从 `if (!isAndroidPlatform) return;` 到方法结束）整体替换为：
```dart
    AudioExportField audioField = field as AudioExportField;

    Directory appDirDoc = await getApplicationSupportDirectory();
    String tempAudioPath =
        '${appDirDoc.path}/${field.uniqueKey}/audioRecorderTemp';
    Directory tempAudioDirectory = Directory(tempAudioPath);

    String tempTimestamp =
        DateFormat('yyyyMMddTkkmmss').format(DateTime.now());

    Directory tempTimestampDirectory =
        Directory('$tempAudioPath/$tempTimestamp');
    tempTimestampDirectory.createSync(recursive: true);
    String tempFilePath = '${tempTimestampDirectory.path}/audio.m4a';
    if (context.mounted) {
      await showAppDialog<File?>(
        context: context,
        builder: (_) => AudioRecorderDialogPage(
          filePath: tempFilePath,
          onSave: (tempFile) {
            String audioRecorderPath =
                '${appDirDoc.path}/${field.uniqueKey}/audioRecorder';
            Directory audioRecorderDirectory = Directory(audioRecorderPath);
            if (audioRecorderDirectory.existsSync()) {
              audioRecorderDirectory.deleteSync(recursive: true);
            }
            audioRecorderDirectory.createSync(recursive: true);

            String finalTimestamp =
                DateFormat('yyyyMMddTkkmmss').format(DateTime.now());
            Directory finalTimestampDirectory =
                Directory('$audioRecorderPath/$finalTimestamp');
            String finalFilePath =
                '${finalTimestampDirectory.path}/audio.m4a';

            finalTimestampDirectory.createSync(recursive: true);
            tempFile.copySync(finalFilePath);

            tempAudioDirectory.deleteSync(recursive: true);

            audioField.setAudio(
              cause: cause,
              appModel: appModel,
              creatorModel: creatorModel,
              newAutoCannotOverride: false,
              generateAudio: () async {
                return File(finalFilePath);
              },
            );
          },
        ),
      );
    }
```
（仅有的两处 `audio.mp3` → `audio.m4a`；删除了 `Permission.microphone` 预检与 Android 早退。）

- [ ] **Step 4: 检查 isAvailable 的调用方是否仍正确**

Run:
```bash
grep -rn "AudioRecorderEnhancement.isAvailable\|isAvailable" hibiki/lib/src/creator | grep -i audio
```
Expected: 确认调用方（创建器增强注册处）会因 `isAvailable => true` 在所有平台暴露录音增强；若调用方此前依赖 Android-only 不需要额外改动（仅可用性扩大）。

- [ ] **Step 5: 分析通过**

Run:
```bash
cd hibiki
D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/creator/enhancements/audio_recorder_enhancement.dart
```
Expected: No issues found（确认 permission_handler 未在本文件残留引用）。

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/creator/enhancements/audio_recorder_enhancement.dart
git commit -m "feat(audio): enable cross-platform recording, output m4a via record"
```

---

## Task 4: Android 声明 RECORD_AUDIO 权限

**Files:**
- Modify: `hibiki/android/app/src/main/AndroidManifest.xml:12`

- [ ] **Step 1: 加入 RECORD_AUDIO**

在第 12 行 `POST_NOTIFICATIONS` 之后、`<application` 之前加入：
```xml
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
```
（原本靠 record_mp3_plus 的 manifest 合并提供；换插件后必须显式声明，否则 `record.hasPermission()` 永远 false、Android 录音直接坏。）

- [ ] **Step 2: 验证 manifest 合法**

Run:
```bash
grep -n "RECORD_AUDIO" hibiki/android/app/src/main/AndroidManifest.xml
```
Expected: 命中一行。

- [ ] **Step 3: Commit**

```bash
git add hibiki/android/app/src/main/AndroidManifest.xml
git commit -m "feat(android): declare RECORD_AUDIO for record plugin"
```

---

## Task 5: iOS 麦克风用途 + 身份修正 + 部署底

**Files:**
- Modify: `hibiki/ios/Runner/Info.plist:8,16`
- Modify: `hibiki/ios/Runner.xcodeproj/project.pbxproj`（bundle id ×3、部署底 ×3）
- Modify: `hibiki/ios/Flutter/AppFrameworkInfo.plist`（MinimumOSVersion）
- Modify: `hibiki/ios/Podfile`

- [ ] **Step 1: 加 NSMicrophoneUsageDescription**

在 `hibiki/ios/Runner/Info.plist` 的 `<dict>` 内（紧接第 4 行 `<dict>` 之后）加入：
```xml
		<key>NSMicrophoneUsageDescription</key>
		<string>Hibiki needs the microphone to record audio for your Anki cards.</string>
```

- [ ] **Step 2: 显示名 jidoujisho → Hibiki**

把第 8 行 `<string>jidoujisho</string>`（CFBundleDisplayName 值）和第 16 行 `<string>jidoujisho</string>`（CFBundleName 值）都改为：
```xml
		<string>Hibiki</string>
```
（两处都是 `jidoujisho`，逐个替换确保 key 对应正确。）

- [ ] **Step 3: bundle id 改为 app.hibiki.reader（与 Android 一致）**

先读 `hibiki/ios/Runner.xcodeproj/project.pbxproj` 确认字符串，再把全部 3 处：
```
PRODUCT_BUNDLE_IDENTIFIER = app.arianneorpilla.yuuna;
```
替换为：
```
PRODUCT_BUNDLE_IDENTIFIER = app.hibiki.reader;
```
（审计确认：bundle id 只在 pbxproj 出现，无 entitlements/URL scheme/app group 引用，Info.plist 用 `$(PRODUCT_BUNDLE_IDENTIFIER)` 变量，改动完全自洽。签名暂不做，此项不影响未签名编译，仅修身份卫生。）

- [ ] **Step 4: 部署底 11.0 → 12.0（record 要求 iOS 12）**

在同一 pbxproj，把全部 3 处：
```
IPHONEOS_DEPLOYMENT_TARGET = 11.0;
```
替换为：
```
IPHONEOS_DEPLOYMENT_TARGET = 12.0;
```

- [ ] **Step 5: AppFrameworkInfo MinimumOSVersion 11.0 → 12.0**

先读 `hibiki/ios/Flutter/AppFrameworkInfo.plist`，把 `MinimumOSVersion` 的值 `11.0` 改为 `12.0`。

- [ ] **Step 6: Podfile 显式 platform**

先读 `hibiki/ios/Podfile`，把被注释的全局平台行启用为：
```ruby
platform :ios, '12.0'
```
（若文件中是 `# platform :ios, '11.0'`，取消注释并改成 12.0。）

- [ ] **Step 7: 自检无遗留旧身份**

Run:
```bash
grep -rn "arianneorpilla\|yuuna\|jidoujisho" hibiki/ios || echo "clean"
```
Expected: `clean`。

- [ ] **Step 8: Commit**

```bash
git add hibiki/ios/Runner/Info.plist hibiki/ios/Runner.xcodeproj/project.pbxproj hibiki/ios/Flutter/AppFrameworkInfo.plist hibiki/ios/Podfile
git commit -m "fix(ios): mic usage desc, bundle id app.hibiki.reader, deploy target 12.0"
```

---

## Task 6: macOS 麦克风用途 + 沙盒联网/录音权限

**Files:**
- Modify: `hibiki/macos/Runner/Info.plist`
- Modify: `hibiki/macos/Runner/Release.entitlements`
- Modify: `hibiki/macos/Runner/DebugProfile.entitlements`

- [ ] **Step 1: macOS 加 NSMicrophoneUsageDescription**

在 `hibiki/macos/Runner/Info.plist` 的 `<dict>` 内（第 4 行 `<dict>` 之后）加入：
```xml
	<key>NSMicrophoneUsageDescription</key>
	<string>Hibiki needs the microphone to record audio for your Anki cards.</string>
```

- [ ] **Step 2: Release.entitlements 补齐 client/server/audio-input**

把 `hibiki/macos/Runner/Release.entitlements` 的整个 `<dict>`（第 4-7 行）：
```xml
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
```
替换为：
```xml
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
```
（根因：发布版沙盒只有 app-sandbox，缺 network.client 会让 WebView/同步/登录全部联网失败；local_assets_server 给 WebView 供 EPUB 资源需要 network.server；录音需要 audio-input。）

- [ ] **Step 3: DebugProfile.entitlements 补齐 client/audio-input**

把 `hibiki/macos/Runner/DebugProfile.entitlements` 的 `<dict>`（第 4-10 行）：
```xml
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
```
替换为：
```xml
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
```

- [ ] **Step 4: Commit**

```bash
git add hibiki/macos/Runner/Info.plist hibiki/macos/Runner/Release.entitlements hibiki/macos/Runner/DebugProfile.entitlements
git commit -m "fix(macos): add network.client/audio-input entitlements + mic usage desc"
```

---

## Task 7: Linux 接入字典 .so + 阅读器标注暂不支持

**Files:**
- Modify: `hibiki/linux/CMakeLists.txt:75`
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1482`
- Modify: i18n（via `tool/i18n_sync.dart`）

- [ ] **Step 1: Linux CMake 构建并安装 hoshidicts_ffi**

在 `hibiki/linux/CMakeLists.txt` 第 75 行 `include(flutter/generated_plugins.cmake)` 之后插入：
```cmake

# === hoshidicts native dictionary engine ===
# Mirror windows/CMakeLists.txt: the Linux runner did not build/bundle the FFI
# dictionary engine, so libhoshidicts_ffi.so was absent and lookups crashed at
# runtime. Build it from the shared native/ tree and install it next to the
# other bundled libs (rpath is $ORIGIN/lib).
set(HOSHIDICTS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../native/hoshidicts")
add_subdirectory("${HOSHIDICTS_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/hoshidicts")
```

- [ ] **Step 2: Linux CMake 安装 .so 到 bundle lib**

在 `hibiki/linux/CMakeLists.txt` 的 Installation 段，`foreach(bundled_library ...)` 块（约第 103-107 行）之后插入：
```cmake

# Install the hoshidicts shared library into the bundle lib dir.
install(TARGETS hoshidicts_ffi LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
```

- [ ] **Step 3: 新增 i18n key（阅读器 Linux 暂不支持文案）**

Run（禁止手改 json，用脚本）:
```bash
cd hibiki
D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat tool/i18n_sync.dart --add reader_unsupported_platform "The reader is not yet available on this platform." "本平台暂不支持阅读器。"
D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat run slang
```
Expected: `t.reader_unsupported_platform` 生成到 `strings.g.dart`，17 语言 json 补齐占位。

- [ ] **Step 4: 阅读器 _buildWebView() 在 Linux 返回占位**

确认 `reader_hibiki_page.dart` 顶部已 `import 'dart:io';`（若无则添加）。把 `_buildWebView()`（第 1482 行）方法体最前面插入 Linux 守卫：
```dart
  Widget _buildWebView() {
    if (Platform.isLinux) {
      // flutter_inappwebview has no Linux backend; the EPUB renderer is
      // unsupported on Linux for now (see docs/specs/2026-05-30-five-platform-build.md).
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.reader_unsupported_platform,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return InAppWebView(
```
（其余 `_buildWebView` 原有内容不变。）

- [ ] **Step 5: 分析通过**

Run:
```bash
cd hibiki
D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/pages/implementations/reader_hibiki_page.dart
```
Expected: No issues found。

- [ ] **Step 6: Commit**

```bash
git add hibiki/linux/CMakeLists.txt hibiki/lib/src/pages/implementations/reader_hibiki_page.dart hibiki/lib/i18n/ hibiki/lib/src/i18n/strings.g.dart
git commit -m "feat(linux): build/bundle hoshidicts_ffi; gate EPUB reader as unsupported"
```
（注意：i18n 生成文件路径以实际为准；只 stage 本任务相关文件。）

---

## Task 8: CI 工作流修正 + 清理死补丁

**Files:**
- Modify: `.github/workflows/build-multiplatform.yml:77-82`
- Delete: `ci/patches/hosted/record_mp3_plus-1.2.0/`

- [ ] **Step 1: iOS job 改用 --no-codesign 真机编译**

把 `.github/workflows/build-multiplatform.yml` 的 iOS 构建步骤（约第 75-82 行）：
```yaml
      # Simulator build needs no signing/Development Team — a pure compile check
      # that still exercises gamepads_ios (GameController) and all iOS plugins.
      - name: Build iOS (debug, simulator)
        working-directory: hibiki
        run: >-
          flutter build ios --debug --simulator
          --dart-define=GOOGLE_OAUTH_CLIENT_ID=${{ secrets.GOOGLE_OAUTH_CLIENT_ID }}
          --dart-define=GOOGLE_OAUTH_CLIENT_SECRET=${{ secrets.GOOGLE_OAUTH_CLIENT_SECRET }}
```
替换为：
```yaml
      # Unsigned DEVICE build: needs no Development Team and links the device
      # arch of all plugins (incl. gamepads_ios / record_darwin). The simulator
      # path is intentionally avoided — historically broke on device-only vendored
      # libs; record_darwin now ships an xcframework so device linking is clean.
      - name: Build iOS (debug, no codesign)
        working-directory: hibiki
        run: >-
          flutter build ios --debug --no-codesign
          --dart-define=GOOGLE_OAUTH_CLIENT_ID=${{ secrets.GOOGLE_OAUTH_CLIENT_ID }}
          --dart-define=GOOGLE_OAUTH_CLIENT_SECRET=${{ secrets.GOOGLE_OAUTH_CLIENT_SECRET }}
```

- [ ] **Step 2: 删除死的 record_mp3_plus 补丁目录**

Run:
```bash
git rm -r ci/patches/hosted/record_mp3_plus-1.2.0
```
（审计确认：该补丁只改 Android Java、目标版本 1.2.0 与 lock 1.5.0 不符、apply-patches.sh 始终跳过；换插件后彻底无用。）

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-multiplatform.yml
git commit -m "ci: iOS no-codesign device build; drop dead record_mp3_plus patch"
```

---

## Task 9: 验证（本地 + 设备 + CI）

- [ ] **Step 1: 全量分析**

Run:
```bash
cd hibiki
D:/flutter_sdk/flutter_extracted/flutter/bin/dart.bat format .
D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze
```
Expected: No issues found（注意 platform_directory_service.dart 的 HEAD 编译错需队友提交其 WIP 后才全绿；本地工作树应已包含其修复）。

- [ ] **Step 2: 全量单测**

Run:
```bash
cd hibiki
D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test
```
Expected: 全部通过（录音对话框/增强若有 widget 测试需同步更新到 record/.m4a）。

- [ ] **Step 3: 验证 Android 原始录音路径（根因修复铁律：复测原失败路径）**

在已连接的 Android 模拟器/真机上构建安装 debug，进入 Anki 制卡 → 触发 Audio Recorder 增强 → 录一段 → 播放 → 保存。确认：
- 系统弹出麦克风授权（RECORD_AUDIO 生效）。
- 生成 `audio.m4a` 且 just_audio 能回放。
- 保存后 AudioExportField 拿到该 m4a 文件。
留存证据到 `.codex-test/`（截图/logcat）。

- [ ] **Step 4: Windows 录音冒烟**

桌面构建运行，确认录音增强在 Windows 出现且能录 + 回放（record_windows 走 MediaFoundation，无外部依赖）。

- [ ] **Step 5: 触发 CI（iOS/macOS/Linux）**

把本轮提交推到 `ci/gamepad-multiplatform` 分支（或新建 `ci/five-platform`），观察 `build-multiplatform.yml`：
- macOS：record_mp3_plus 移除后 11.0 部署底约束消失，pod 解析通过 → 绿。
- iOS：`--no-codesign` 真机编译 + record_darwin xcframework → 绿。
- Linux：**取决于队友提交 platform_directory_service.dart**；其提交后，hoshidicts_ffi 接入应让 `flutter build linux` 产出含 libhoshidicts_ffi.so 的 bundle。若 native/hoshidicts 的 zstd/glaze 等在 clang/Linux 下编译失败，单独排查（属 native 构建问题，非本插件迁移）。

- [ ] **Step 6: 回归 Linux .so 落地**

CI Linux job 内（或本地 Linux）确认：
```bash
ls build/linux/*/debug/bundle/lib/libhoshidicts_ffi.so
```
Expected: 文件存在。

---

## 不在本计划范围（按用户决策显式排除）

- **iOS/macOS 签名与上架**：暂不做。需要时另起一条 secrets-gated 发布工作流 + 付费 Apple Developer 账号（$99/年，覆盖 iOS+macOS）。
- **Linux EPUB 阅读器真实渲染**：暂不支持，本计划只做"明确标注 + 不崩"。真要支持需 WebKitGTK 后端（大改，上游无现成）。
- **队友 picker 重构提交**：不属本计划，等其提交 `platform_directory_service.dart`。

---

## Self-Review

**Spec coverage：**
- record_mp3_plus 双 CI 红 → Task 1（移除）+ Task 5（iOS 部署底）+ Task 6（macOS 权限）✅
- 全平台录音 → Task 1/2/3（record + .m4a）+ Task 4（Android 权限）+ Task 5/6（iOS/macOS 麦克风）✅
- Linux 字典 .so 缺失 → Task 7 Step 1-2 ✅
- Linux 阅读器无 WebView → Task 7 Step 3-4（标注暂不支持）✅
- macOS 发布版联网断 → Task 6 Step 2-3 ✅
- iOS 身份遗留 → Task 5 Step 2-3 ✅
- CI 走错 --simulator → Task 8 Step 1 ✅
- 死补丁 → Task 8 Step 2 ✅

**Type 一致性：** `AudioRecorder`/`RecordConfig`/`AudioEncoder.aacLc`/`record.hasPermission()`/`record.start(...,path:)`/`record.stop()`/`record.dispose()` 在 Task 2/3 全程一致；文件名统一 `audio.m4a`；i18n key 统一 `reader_unsupported_platform`。

**Placeholder 扫描：** 各 step 均给出确切文件、确切前后代码、确切命令与期望输出；唯二需"先读再改"的是 pbxproj/Podfile/AppFrameworkInfo（因 Edit 需精确匹配，且行号可能漂移），已在步骤中标注先读确认字符串。
