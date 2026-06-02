# 构建与依赖补丁

> [CLAUDE.md](../../CLAUDE.md) 的子文档。面向 agent 和贡献者的构建细节；快速上手见 [README.md](../../README.md) 的「构建」。

## 平台

5 个平台均出包：**Android / iOS / macOS / Windows / Linux**。
- Android 走 Material Design 3，iOS 走 Cupertino，桌面端复用 Material 架构。
- Windows / Linux 桌面端依赖 fork 的 `flutter_inappwebview_windows` 渲染 EPUB（Linux 阅读器能力受限）。
- 词典引擎 `hoshidicts`（C++ FFI）在各平台均已接线。

## Melos workspace

仓库根是一个 Melos workspace（`hibiki_workspace`，约束 `melos: ^7.7.0`，写在根 `pubspec.yaml`）。`melos.yaml` 定义的脚本：

| 脚本 | 作用 |
|------|------|
| `melos run analyze` | 全工作区静态分析 |
| `melos run test` | 全工作区单元/Widget 测试 |
| `melos run dev` | 开发辅助 |
| `melos run build:android` | 构建 Android APK |

## 一键准备 + 构建（Android）

```bash
# 仓库根
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define-from-file=dart_defines.env
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` 把三件事收敛成一条命令：①若缺 `hibiki/dart_defines.env` 则从 `dart_defines.env.example` 自动生成（占位 OAuth 值即可编译，仅 Google Drive 备份需要真实值）；②`flutter pub get`；③运行 `ci/apply-patches.sh`。`melos bootstrap` 经 post hook 做同样的 ②③（Windows 上 melos 有 CJK 编码 bug，改用 `tool/bootstrap.ps1`）。

Android SDK 级别：`compileSdk 36` / `minSdkVersion 24` / `targetSdk 35`。

## 两套依赖修补机制

本项目锁定 Flutter 3.41.6，部分上游依赖未适配。修补分两条路，**互不重叠**：

### 1. 入库 vendored（`third_party/` + `dependency_overrides`）

凡是要作为构建输入、跨机/CI 一致复现的补丁包，直接 vendor 到 `third_party/` 并在 `hibiki/pubspec.yaml` 用 `dependency_overrides` 的 `path:` 指向。这些包从仓库内解析，**不需要**打 pub-cache 补丁：

| 包 | 用途 |
|---|---|
| `flutter_inappwebview_windows` | Windows EPUB 渲染 fork（在 `packages/`） |
| `flutter_inappwebview_android` | Android WebChromeClient 在 compileSdk 36 的公开方法修复（在 `third_party/`） |
| `gamepads_android_stub` | `gamepads_android` 的 no-op stub，避免原插件启动崩溃（在 `packages/`） |
| `network_to_file_image` | Flutter 3.x API 兼容（`hashValues`→`Object.hash`、`ImmutableBuffer` 等，在 `third_party/`） |
| `carousel_slider` | `CarouselController` 命名冲突修复（在 `third_party/`） |
| `fading_edge_scrollview` | `PageController` 类型修复（在 `third_party/`） |

新增此类补丁照此 vendor，并把其 pubspec 的 SDK 上界 bump 到 `<4.0.0`（Dart 3）。`third_party/` 下的 fork 必须**整包入库**（含 `android/src/main/res/*.xml` 等），`.gitignore` 已用 `!third_party/**/*.xml` 负向豁免，否则 fresh checkout 会因缺资源而构建失败。

### 2. pub-cache 补丁（`ci/apply-patches.sh`）

其余仍走 pub.dev/git 的包，由 `ci/apply-patches.sh` 把 `ci/patches/{hosted,git}/<包-版本>/` 下的改动覆盖到实际 pub cache（`audio_session`、`fluttertoast`、`flutter_blurhash`、`file_picker`、`image_picker_android`、`mecab_dart`、`package_info_plus`、`path_provider_android`、`permission_handler_android`、`sqflite`、`uri_to_file`、`url_launcher_android`、`win32`、git 的 `receive_intent` 等）。

- 补丁目录按**精确版本号**命名。lock 版本漂移后旧补丁目标缺失，脚本**跳过并警告**而不是假装成功（HBK-AUDIT-005）。
- 每次清 pub cache 或重新 `flutter pub get` 后必须重跑（`bootstrap` 已包含这步）。

> 与机制 1 重叠的包（如 `carousel_slider` / `fading_edge_scrollview` / `network_to_file_image`）即使 `ci/patches/hosted/` 下还留有同名目录，因 `dependency_overrides` 已把它们指向 `third_party/`，pub-cache 目标版本对不上 → 自动跳过，以 vendored 版本为准。

## Android Manifest 关键组件

`hibiki/android/app/src/main/AndroidManifest.xml`：

- **MainActivity** — `singleTask`，支持画中画（PiP）。
- **PopupDictActivity** — 弹窗词典，独立进程 `:popup`，响应 `PROCESS_TEXT` / `SEND` / `hibiki://lookup`。
- **FloatingDictService** / **FloatingLyricService** — 悬浮窗前台服务。
- **DictAccessibilityService** — 无障碍词典服务。
- **FloatingDictTile** — 快捷磁贴。
- 3 个启动器图标别名：`MainActivityDefault` / `MainActivityHibikiFull` / `MainActivityHibikiMinimal`，运行时切换。
- 权限：`MANAGE_EXTERNAL_STORAGE` / `SYSTEM_ALERT_WINDOW` / `FOREGROUND_SERVICE`(+`_MEDIA_PLAYBACK`/`_SPECIAL_USE`) / `REQUEST_INSTALL_PACKAGES` / AnkiDroid `com.ichi2.anki.permission.READ_WRITE_DATABASE`。

## iOS / macOS 远程构建

Windows 跑不了 Apple 模拟器，iOS/macOS 构建走局域网内一台远程 Mac。连接信息（SSH 主机/端口）、CocoaPods 在 ruby 2.6 上的钉版清单、构建/运行/热重载流程是**本机私密信息**，放未入库的 `AGENTS.local.md`，需要时读取，换机器手动重建。

## 验证命令

格式化、测试固定用（在 `hibiki/` 下）：

```powershell
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test
```

改 Android 资源/manifest/Gradle/权限/通知/前台服务/打包行为时，还要：

```powershell
cd hibiki\android
.\gradlew.bat :app:assembleRelease
```
