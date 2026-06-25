# 集成测试与设备验证

> [CLAUDE.md](../../CLAUDE.md) 的子文档。执行前先读 CLAUDE.md 的「基本规则」「验证」。

集成测试只跑在**模拟器**上：`ci/integration-test.sh` 忽略物理真机，只用 `emulator-<port>` 序列号。无模拟器在线时会自动从 AVD 启一台。

## 测试三层架构（禁止手动 adb / 手动点击）

所有测试通过脚本完成，不允许手工执行 `adb` 命令或手动在模拟器上点击。

| 层级 | 工具 | 职责 | 适用场景 |
|------|------|------|----------|
| **编排（推荐）** | `ci/integration-test.sh` | 选/启模拟器 + 构建 + provision + 跑全部目标 + 汇总 | 一键全自动跑集成测试 |
| **文件操作** | `ci/emulator-test.sh` | 推送素材、授权限、触发 MediaScanner | 仅需准备素材时 |
| **状态验证** | `run-as app.hibiki.reader sqlite3 files/hibiki.db` | 直查 `hibiki.db` | 导入结果、配置持久化、cue 数量、Profile |
| **UI 交互** | `flutter drive` 集成测试 | CJK 搜索、阅读器翻页、划词查词 | 单独跑某个目标 |

### 关键约束

- ADB 脚本（`ci/*.sh`）**不得**向 Flutter 文本框输入 CJK——`input text` 在 Android 上不支持 Unicode，`settext.jar` 找不到 Flutter 的 EditText。CJK 文字输入只能通过 `tester.enterText()` 在 Flutter 集成测试里完成。
- 导入验证优先用 DB 查询（`run-as app.hibiki.reader sqlite3 files/hibiki.db`），不依赖 UI dump 匹配文字。
- **UI 交互一律焦点驱动，禁止坐标点击。** Flutter 集成测试操作真 app **只发框架级合成按键**（`tester.sendKeyEvent`，经 `FocusDriver`），绝不用 `tester.tap` / 坐标点击，也不用 ADB 截图猜坐标 `input tap`——点击依赖精确屏幕位置，布局/滚动/缩放/平台一变就错位易错；焦点+键位置无关且三端一致。详见下方「焦点驱动操作」。
- adb 用 Android SDK 自带的 `platform-tools/adb`（`$ANDROID_HOME` 下；确保版本够新），不要依赖 PATH 里可能过时的 adb。
- 需要新增测试流程时，先判断属于哪一层，不要在错误的层做事。
- 不要在同一台模拟器上并发跑两个编排脚本——日志会互相污染。

## 焦点驱动操作（不用点击，三端一致）

焦点 + 合成按键**位置无关**，而且**不要求 OS 窗口真获得焦点**——所以同一份测试在模拟器、Windows 离屏 runner、Mac 离屏 runner 上机制完全一致（为何禁坐标点击见上「关键约束」）。

**原语**：`integration_test/helpers/focus_driver.dart` 的 `FocusDriver`（只发 `tester.sendKeyEvent`，绝不 `tester.tap`）：

| 方法 | 键 | 作用 |
|---|---|---|
| `reachAll()` | `Tab` | 遍历当前页可达焦点；**Tab 本身会把懒加载列表滚动 + 构建出屏外的行**（所以别用 `find.byType(X).first` 硬定位——页顶可能没有目标控件） |
| `focusWidget(finder)` | `Tab` | Tab 到焦点落进 finder 子树 |
| `activate()` | `Enter` | 激活开关 / 按钮（**确认不走空格**——App 已把裸空格中和为 `DoNothingIntent`，焦点确认统一 Enter / 手柄 A，见 `lib/src/shortcuts/global_navigation.dart`） |
| `adjust(steps:)` | `←/→` 方向键 | 加减（Slider/Stepper/Segmented 是 `_GamepadAdjustableValue` 单一焦点停靠点，不用 Space） |

**标准操作模式**（见 `integration_test/comprehensive_settings_test.dart` 与 widget 层 `test/settings/settings_schema_coverage_test.dart`）：
`Tab` 遍历 → 对落到的每个控件**检测类型**（向上遍历 widget 祖先找 `AdaptiveSettings{Switch,Slider,Stepper,Segmented}Row`）→ **按类型驱动**（Switch→`Enter`，可调→方向键）→ 断言**真写穿 DB / 真生效**（不只点几下）→ **还原** prefs（不动用户真实设置）。

**激活键的平台差异**：app 主激活是手柄 `gameButtonA`——模拟器（Android）能合成它；**桌面（Windows/Mac）合不出**（无物理键映射，`sendKeyEvent(gameButtonA)` 抛 "not found in windows physical key map"）→ 桌面用 `Enter`（不走 `Space`，见上表）。`Tab` 与方向键到处都行，优先用它们。

**为何能离屏后台跑**：合成按键走 Flutter 框架（不走 OS），与窗口是否在前台无关。桌面 runner 认环境变量 `HIBIKI_TEST_HIDDEN` 把窗口停到屏外 + 不抢前台（`windows/runner/win32_window.cpp` / `macos/Runner/MainFlutterWindow.swift`），不挡你用电脑。

**三端跑同一份焦点驱动测试**（可见应用巡检和截图取证流程见 [computer-use-testing.md](computer-use-testing.md)）：
```bash
# 模拟器（Android，gameButtonA 可合成）
flutter test integration_test/<t>_test.dart -d emulator-<port>     # 或 ci/integration-test.sh
# Windows 离屏后台（PowerShell，仓库根）
.\hibiki\tool\run_windows_itest.ps1 integration_test/<t>_test.dart
# Mac 跨机（Windows 当总指挥，sync→Mac ff→跑）
.\tool\run_mac_itest.ps1 integration_test/<t>_test.dart
```

`reader_computer_use_flow` 在 Windows runner 下还会把可见验收证据（function-matrix、flutter-ui-tree、截图）写进 `.codex-test/windows-itest/<run-id>/computer-use/...`——产物清单、判读规则、「截图缺失≠功能失败」见 [computer-use-testing.md](computer-use-testing.md)。

## 一键运行（全自动，仅模拟器）

集成测试的唯一入口是 `ci/integration-test.sh`：自动选/启一台模拟器（物理真机会被忽略），构建一次 debug APK，自动 provision 所有前置（AnkiDroid 安装+建 collection+授权、字典 zip 推 `/sdcard`），再遍历全部 `integration_test/*_test.dart` 目标逐个 `flutter drive`，最后打印分类 PASS/SKIP/FAIL 汇总（任一失败退出非零）。

```bash
bash ci/integration-test.sh                      # 起/选模拟器，构建，provision，跑全部目标
bash ci/integration-test.sh --skip-build         # 复用已构建的 app-debug.apk
bash ci/integration-test.sh --only=app_smoke,reader_pagination
bash ci/integration-test.sh --avd=hoshi_test_api35
```

每个目标的日志落在 `.codex-test/itest-logs/<target>.log`。

当前 `ci/integration-test.sh` 的静态 `ALL_TARGETS` 共 **20** 个目标：`anki_integration`、`app_smoke`、`comprehensive_imports`、`comprehensive_reader_lookup`、`comprehensive_settings`、`feature_flows`、`gamepad_navigation`、`home_keyboard`、`image_pause_detection`、`navigation_stability`、`popup_dictionary`、`reader_caret`、`reader_computer_use_flow`、`reader_dictionary`、`reader_keyboard`、`reader_pagination`、`reader_popup_caret`、`regression`、`settings_validation`、`user_path`。runner 不自动 glob，新增目标必须同时加入该列表。

书库依赖类测试（`reader_dictionary` / `reader_keyboard` / `reader_computer_use_flow` / `regression`）由 `integration_test/helpers/library_fixture.dart` 在测试内自带 fixture，全新安装也无需手动导入（fixture 细节见下方「测试素材」）。

## AnkiDroid 集成测试

AnkiDroid API（`AddContentApi` ContentProvider）的真实链路验证必须走 `ci/anki-integration-test.sh`，不要手动拼 `flutter drive`：

```bash
bash ci/anki-integration-test.sh              # 完整：装 AnkiDroid -> 建 collection -> 建 APK -> 授权安装 -> 跑测试
bash ci/anki-integration-test.sh --skip-build # 复用已构建的 app-debug.apk
```

脚本覆盖（对应 `integration_test/anki_integration_test.dart`）：`fetchConfiguration()` 返回真实 decks/note types、`isDuplicate()`、`mineEntry()` add-or-duplicate。

**为什么需要独立脚本（关键约束）：** AnkiDroid API 受 *dangerous* 权限 `com.ichi2.anki.permission.READ_WRITE_DATABASE` 管控，Android 只在用户点了 AnkiDroid 运行时弹窗「Allow」后才授予。Hibiki 在运行时正确发起请求（`AnkiChannelHandler.java` 的 `ankiDroid.requestPermission(...)`），但自动化 `flutter drive` 每次全新安装且无法点系统弹窗，于是 fresh-install 一律返回 `AnkiFetchError`。脚本用 `adb install -g`（授予全部运行时权限 = 等价用户点 Allow）预装 APK，`flutter drive` 的 `-r` 重装会**保留**该授权，从而确定性复现已授权状态。这是测试夹具步骤，**不是**产品代码里的绕过。

`adb install -g` 不可省略：`flutter drive` 收尾会卸载 app，下一次运行是全新安装、无授权——所以每轮都要先 `-g` 预装。脚本已做幂等处理。`ci/anki-integration-test.sh` 的 provision 逻辑被 `ci/integration-test.sh` 经 `ci/lib/provision-ankidroid.sh` 复用。

## ADB 降级安装（不卸载）

Android 14+ 的 `adb install -d` 在 user build 真机上会被拒绝（`INSTALL_FAILED_VERSION_DOWNGRADE`）。用 `cmd package install` 替代：

```bash
adb push app.apk /data/local/tmp/downgrade.apk
adb shell "cmd package install -d -r /data/local/tmp/downgrade.apk"
```

| 方法 | Android 15 模拟器 | Android 16 真机 (user build) |
|------|-------------------|------------------------------|
| `adb install -r -d` | 成功 | 失败 |
| `pm install -r -d` | 成功 | 失败 |
| `cmd package install -d -r` | 成功 | 成功 |

注意：`pm uninstall -k`（保留数据卸载）后再装低版本同样会被 Android 16 拒绝，必须用 `cmd package install -d` 或完全卸载。

## DB 状态验证查询

```sql
SELECT name FROM dictionary_metadata;   -- 字典是否导入
SELECT title, author FROM epub_books;   -- EPUB 是否导入
SELECT COUNT(*) FROM audio_cues;        -- 字幕 cue 数量
SELECT COUNT(*) FROM preferences;       -- 偏好设置条数
SELECT name FROM profiles;              -- Profile 列表
```

## 测试素材

自动化集成测试**不依赖任何外部素材**：库依赖类测试（`reader_dictionary` / `reader_keyboard` / `reader_computer_use_flow` / `regression`）由 `integration_test/helpers/library_fixture.dart` 自带 fixture —— `seedReaderBook` 用 `EpubGenerator`+`EpubImporter` 程序化导入合成 EPUB，`seedDictionary` 导入 runner 推送的字典或生成最小测试字典。全新安装也能跑，无需准备任何文件。

需要用真实素材做手动/额外测试时（各人路径不同，不写死）：

- 把自己的 EPUB / 音频 / 字幕 / 字典(`.zip`) 放进仓库外的 `.codex-test/fixtures/<任意名>/`（`.codex-test/` 整体 gitignored，不入库），在脚本或测试里引用该路径；或直接在 app 内手动导入。
- 临时截图、UI XML、logcat 片段也放 `.codex-test/` 下，并在最终回复里给出具体路径。
- 推送到模拟器时用 ASCII 文件名（避免 Windows/adb 对 CJK 文件名抽风）；大文件推送后用 `adb shell ls -lh` 确认大小，不要只信 `adb push` 的一行输出。

## 手工验证与证据留存

- 真机/导入必须通过 DocumentsUI 选择测试文件，或用等价的已授权 `content://` URI；不要用 `file:///sdcard/...` 或 shell 拼出的未授权 `content://...` 冒充真实导入。
- 默认保留模拟器 app 数据；除非目标要求首启/空库/重复导入/迁移/损坏恢复，或用户明确要求干净导入，否则不要 `pm clear`。确实清数据时必须在回复中说明。
- 安装包测试先确认设备 ABI 和 APK variant：`x86_64` 模拟器装 `app-x86_64-release.apk`，arm64 真机装 `app-arm64-v8a-release.apk`。不要用本地源码状态代替已安装 APK 的行为。
- 阅读器/导入/播放/布局问题必须用真实模拟器或用户指定设备复测，并留下证据路径。每次安装包或阅读器手工测试至少记录：
  - APK 路径、`versionName`、`versionCode`、安装设备序列号和 ABI。
  - 测试数据来源路径，以及推送到设备后的路径和大小。
  - 关键截图（`.codex-test/<case>.png`）、UI hierarchy（`.codex-test/<case>.xml`）、logcat 证据路径。
- 对遮挡/布局类问题，除截图外还要记录边界数据：WebView bounds、正文节点 bounds、遮挡控件 bounds。
- 对导入类问题，logcat 至少筛 `hibiki-import`、`BookImportDialog`、`EpubImporter`、`ReaderHibiki`、`Renderer process`、`AndroidRuntime`、`Exception`、`Error`。
- 真机锁屏、权限弹窗、DocumentsUI 不可达、文件未显示等都当作测试阻塞明确说出来；不要把未测到的路径说成通过。
- 不要把「导入成功」和「阅读器渲染正确」混为一个结论；导入、打开、播放、布局验证要分开说。
