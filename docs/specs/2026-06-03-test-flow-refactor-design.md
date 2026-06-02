# 测试流程重构：焦点驱动 · schema 全量生效校验 · 跨机后台执行

> 日期：2026-06-03 · 分支：develop
> 关联前作：`docs/specs/2026-06-01-comprehensive-test-automation-plan.md`、`docs/specs/2026-05-30-integration-test-automation.md`、`docs/agent/integration-testing.md`
> 本文是**设计（spec）**，经用户确认后进 `superpowers:writing-plans` 出实现计划。

## 1. 背景与问题

现状（已盘点，非从零）：

- **Android 模拟器链路成熟**：`ci/integration-test.sh` 一键起模拟器 → 构建 debug APK → provision（AnkiDroid + 字典）→ 跑 18 个 `flutter drive` 目标 → 汇总 PASS/SKIP/FAIL。**必须复用，不重写。**
- **跨平台矩阵骨架已存在**：`hibiki/tool/comprehensive_test_runner.dart` + `tool/test_flow/`（`comprehensive_test_matrix.dart` / `comprehensive_test_executor.dart` / `comprehensive_test_reporter.dart`）是一个 Android/Windows/macOS × 10 场景的矩阵 runner，但**桌面目标只在「本机=目标平台」时才跑，否则标 `blocked`** —— 没有真正跨机调度，Mac 永远跑不到。
- **「真验证」的种子已有但不彻底**：`integration_test/settings_validation_test.dart` / `comprehensive_settings_test.dart` 已会回读 Drift `preferences` 表确认写穿（`prefsRepo.refreshFromDb()` + 快照 diff），但：① 用 `tester.tap()` 坐标点击 + 部分直接调 `onChanged`，**没用焦点导航**；② 覆盖不是按 schema 全量；③ **只验"写穿 DB"，不验"真生效"**。

四个实打实的痛点：

1. 坐标点击会打偏 / 漏控件 / 受滚动影响出错。
2. Mac 端完全没有自动化。
3. 桌面测试会弹窗抢前台，打断正常用电脑。
4. 「验证生效」不成体系——改了 DB 不等于用户看到的行为/渲染真的变了。

## 2. 目标与边界

- **一条命令**（在 Windows 上）覆盖 Android 模拟器 + Windows 桌面 + 远程 Mac 三端，结果统一汇总。
- 桌面端测试窗口**离屏 + 不抢前台焦点 + 不接管真实鼠标键盘**，跑测试时用户能继续正常用电脑。
- UI 交互**一律走焦点导航（`tester.sendKeyEvent`）**，不用坐标点击。
- 配置项**按 settings schema 全量**：每项 焦点定位 → 改值 → 回读 DB → **断言真生效** → 还原。
- 核心功能流（导入/打开/查词/播放/翻页/Anki/同步）断言改成"真验证"。
- **不破坏** `ci/integration-test.sh`（复用）。

非目标（YAGNI）：

- 不上 GitHub Actions（Mac 访问 GitHub 不稳；要本地后台跑）。
- 不引入 `window_manager` 等新依赖（用现成 runner 原生代码）。
- 不做 iOS（用户未提；模拟器只在 Mac）。
- 不维护全图 golden master（除极少数稳定界面，见 §6）。

## 3. 关键技术事实（已在代码中坐实）

- **焦点驱动可行且唯一可靠**：`integration_test/gamepad_navigation_test.dart` 已证明 `tester.sendKeyEvent(arrowDown/Right/…)` 驱动真实焦点系统，`FocusManager.instance.primaryFocus` 读当前焦点。注释明确：`adb input keyevent` 驱动不了 Flutter，**只有 in-engine `sendKeyEvent`** 行。它注入 Flutter 引擎合成事件，**不碰真实输入设备、不要求 OS 窗口真获得焦点** —— 这是"后台 + 焦点驱动"成立的根因。激活语义：Switch/按钮用 Space/Enter/`gameButtonA`；返回用 `gameButtonB`（`HibikiPopIntent`）。
- **schema 可程序化遍历**：`hibiki/lib/src/settings/settings_schema.dart` 的 `buildSettingsSchema(SettingsContext)` → `List<SettingsDestination>` 可 import；`destinations.expand((d)=>d.sections).expand((s)=>s.items)` 拿全部 `SettingsItem`（带 `id`、运行时类型=控件类型、`value`/`onChanged` 回调）。类型定义在 `settings_destination.dart`（`SettingsSwitchItem` / `SettingsSegmentedItem<T>` / `SettingsSliderItem` / `SettingsStepperItem` / `SettingsCustomItem` / `SettingsNavigationItem` / `SettingsActionItem`）。
  - **坑 1**：item 的 `id`（如 `lookup.auto_search`）**≠ 持久化 key**（如 `auto_search`）。key 是 `PreferencesRepository.getPref/setPref` 里的字面量，藏在回调调用的 model 方法内部。→ 验"写穿"靠整张 `prefsSnapshot` 前后 diff，不靠 id→key 映射。
  - **坑 2**：Sync 组（`sync_settings_schema.dart` 的 `buildSyncBackupDestination()`）是 `SettingsCustomItem` + 独立 `SyncRepository`（不走 `PreferencesRepository`/profile 投影），要特判。
  - profile 范围过滤规则在 `profile/profile_keys.dart`（`ProfileKeys.isExcludedPref`）。
- **生效探针落点已坐实（具体可调，非空话）**：
  - 阅读器 CSS 是纯函数 `ReaderContentStyles.css({required ReaderSettings settings, …})`（`hibiki/lib/src/reader/reader_content_styles.dart:47`），输出串含 `writing-mode: ${settings.writingMode}`、`font-size: ${settings.fontSize}px`、furigana/对齐/分栏/缩进。
  - 词典字号在 `dictionary_structured_content_page.dart:105` 经 `ref.read(appProvider).dictionaryFontSize` 注入渲染调用。
- **Mac 同步契约**：`tool/sync_to_mac.ps1` 拒绝 dirty worktree（除非 `-AllowDirty` 仅推 commit）、只 fast-forward、分叉即停。远端：`ssh shfaifsj@192.168.1.34`，代码在 `~/dev/hibiki`，构建按 `CLAUDE.local.md`（PATH/LANG/cocoapods 钉版）。
- **截图限制**：`integration_test/test_helpers.dart:7` 写 `screenshotsAreRequired => … != TargetPlatform.windows` —— **Windows 上 `binding.takeScreenshot` 不支持**。且测试模拟器 WebView renderer 会崩，reader 内容截不到。→ 截图不能当跨平台主判据。

## 4. 三大核心机制

### A. 焦点驱动器 `integration_test/helpers/focus_driver.dart`（新增）

无状态 helper，封装现有 `sendKeyEvent` 原语，**全程不用 `tester.tap` 坐标点击**：

- `Future<List<FocusNode>> reachAll(WidgetTester tester, {int maxSteps})`：用 Tab/方向键遍历当前页，记录每次 `primaryFocus`，返回去重后的可达焦点序列。供"可达性断言"。
- `Future<bool> focus(WidgetTester tester, Finder target, {int maxSteps})`：按方向键直到 `primaryFocus` 落在 `target` 的可聚焦后代上；返回是否成功（不可达 = 真 bug）。
- `Future<void> activate(WidgetTester tester)`：对当前焦点发 Space/Enter（必要时 `gameButtonA`）。
- `Future<void> adjust(WidgetTester tester, {required int steps})`：对当前焦点发 N 次方向键（调 Slider/Stepper/Segmented）。
- `Future<void> back(WidgetTester tester)`：发 `gameButtonB`/Esc 走 `HibikiPopIntent`。

所有方法用**有界 `pump`（非 `pumpAndSettle`）**——live home 有永不 settle 的动画（见 gamepad 测试注释）。

### B. schema 全量生效校验器 `integration_test/helpers/schema_settings_verifier.dart`（新增）

import `buildSettingsSchema`，扁平化全部 item。对每个可操作 item 执行**五步**，产出结构化 `ItemVerdict`：

1. **before**：读 `item.value()`（如适用）+ 整张 `prefsRepo.prefsSnapshot`（Sync 组读 `SyncRepository`）。
2. **reached**：用焦点驱动器把焦点移到该控件，记录是否可达。
3. **changed**：按运行时类型分派改值——Switch→`activate`；Slider/Stepper/Segmented→`adjust`；Picker/Custom→打开选择后选另一项。读 after 值，断言 `value()` 变了。
4. **persisted**：`refreshFromDb()` 后断言 `prefsSnapshot`（或 SyncRepository 回读）变了——证明写穿。
5. **effect-verified（§5 的核心）**：查 effect-probe registry，跑对应探针断言真生效。
6. **restored**：还原到 before。

`ItemVerdict { id, controlType, reached, changed, persisted, effectVerified, effectProbeKind?, restored, note }`。

校验器**不静默放水**：任一 item 缺 effect 探针 → `effectVerified=false` 且 `note="EFFECT UNVERIFIED: no probe"`，在报告里逐条列为待补缺口（不算 PASS）。

### C. effect-probe registry `integration_test/helpers/effect_probes.dart`（新增）

设置汇流到 ~5 个渲染管线，探针按**族**参数化（不手写 100 个）：

| 族 | 覆盖设置 | 探针级 | 实现 |
|---|---|---|---|
| 主题/外观 | 暗色、调色板、对比 | T2 | 读 `Theme.of(ctx)` / `ColorScheme` |
| 阅读器内容样式 | 字号、竖排、振假名、对齐、分栏、缩进、间距、内边距 | **T1**(+桌面 T3) | 调 `ReaderContentStyles.css(settings)` 断言输出串含新值；桌面再 evalJS 读 `getComputedStyle` |
| 词典显示 | 词典字号、结构化样式 | T1/T2 | 词典渲染输入 / 消费控件属性 |
| 阅读器行为 | 分页/连续模式、RTL、翻页 | T1/T2 | 分页脚本生成 / `ReaderHibikiSource` 状态 |
| 查词/听力行为 | auto-search、自动播放等 | T4 | 触发动作断言结果 |

`EffectProbe { kind(T1..T5), Future<bool> verify(...) }`；registry 按 item.id 或 category 匹配。

## 5. 验证标准（PASS 的定义）

**配置项 PASS = `reached ∧ changed ∧ persisted ∧ effectVerified ∧ restored`，五者缺一不算过。**

- **只写穿 DB 但没探到生效 = WARN / 部分通过，报告明确标出，绝不算 PASS。**
- 「生效」探针四级（精确度递减，T1 最强）：
  - **T1 渲染输入（强、跨平台含模拟器）**：调纯生成函数（`ReaderContentStyles.css` / 词典 CSS / 主题），断言输出含新值——证明设置真流进渲染输入。
  - **T2 控件树**：读真实消费控件属性（`Theme.brightness`、导航顺序、Flutter 端字号、控件出现/消失）。
  - **T3 WebView DOM（桌面/Mac/真机）**：evalJS 读 `getComputedStyle` 断言布局后真实值；模拟器 WebView 崩→跳过并标注 `T3 SKIPPED (emulator webview)`。
  - **T4 行为**：触发动作看结果。
  - **T5 截图（仅证据 + 粗粒度方向性辅助，非判据）**：见 §6。

功能流"真验证"判据：导入→DB 有行；打开→WebView content-ready 标记；查词→`home_dictionary_result_evidence` key 出现；翻页→进度/标记变化；播放→cue 高亮推进；Anki→真实 decks/duplicate；同步→`SyncRepository` 回读一致。

**三平台各加一层、不冗余**：模拟器覆盖 T1+T2+T4；桌面(Windows/Mac)额外补 T3 真实 WebView DOM。

## 6. 截图的角色（已定调：证据 + 粗粒度辅助，不当判据）

- 自动 PASS 门槛**只认结构化探针**（T1+桌面 T3）。
- 每个可视设置额外 `takeScreenshot` **留档**（`.codex-test/` 下），供人工/AI 肉眼复查。**Windows 端跳过截图**（`takeScreenshot` 不支持），不因此判失败。
- 对少数视觉显著设置做**粗粒度方向性断言**（非像素 golden）：如暗色→采样背景像素亮度下降；字号→裁剪区文本高度变高。对 AA/子像素鲁棒、不用 golden。
- 全图 golden master 仅对极少数稳定界面（固定 EPUB + 固定设置的阅读器页）、per-platform、仅 WebView 可用平台；作为可选增强，非本次必做。

## 7. 跨机编排 + 后台化（扩 `tool/test_flow/`，不重写）

- **Android（host=Windows）**：matrix 的 android 场景**委托 `ci/integration-test.sh --only=<映射目标>`**（它已处理 emulator boot/provision/drive），并加 `emulator -no-window`（headless，彻底后台）。不再让 comprehensive runner 裸跑无 provision 的 `flutter drive`。
- **Windows**：`flutter test integration_test/<target> -d windows`，带 `--dart-define=HIBIKI_TEST_HIDDEN=1`；改 `hibiki/windows/runner/`（`win32_window.cpp` / `flutter_window.cpp`，C++ 平台边界，**无新依赖**），在该标志下窗口**移到屏幕外坐标 + `ShowWindow(SW_SHOWNOACTIVATE)`**（不抢前台、不进可视区）。若离屏坐标下 GPU/ANGLE 异常 → **降级最小化 + 不激活**（仍不抢前台）。
- **macOS（host=Windows）**：新增 `tool/dispatch_mac.ps1`：① 校验已 commit（否则停）；② `sync_to_mac.ps1` 推 commit；③ `ssh shfaifsj@192.168.1.34` 在 `~/dev/hibiki` `git pull --ff-only` 后跑 `comprehensive_test_runner.dart --platform=macos`（按 `CLAUDE.local.md` 配 PATH/LANG/cocoapods）；④ `scp` 拉回报告目录；⑤ 合并进总汇总。Mac 是无人远程机，不存在打扰，正常跑（可选同样带 hidden 标志改 `macos/Runner/`）。
- 报告走 scp/文件，不进 git（`.codex-test/` 已 gitignore）。

## 8. 文件 / 模块改动清单

新增：
- `hibiki/integration_test/helpers/focus_driver.dart`
- `hibiki/integration_test/helpers/schema_settings_verifier.dart`
- `hibiki/integration_test/helpers/effect_probes.dart`
- `hibiki/integration_test/settings_schema_coverage_test.dart`（schema 全量、焦点驱动、生效校验）
- `tool/dispatch_mac.ps1`

改动：
- `hibiki/integration_test/comprehensive_settings_test.dart` / `settings_validation_test.dart`：tap → 焦点驱动器 + 生效探针（保留目标名，矩阵引用不变）
- `hibiki/windows/runner/win32_window.cpp`（+ 必要时 `flutter_window.cpp`）：`HIBIKI_TEST_HIDDEN` 离屏 + 不激活
- `hibiki/tool/test_flow/comprehensive_test_matrix.dart` / `comprehensive_test_executor.dart`：android 委托 integration-test.sh、windows 注入 hidden 标志、macos 跨机分派；新增 effect-tier 标注
- `hibiki/tool/test_flow/comprehensive_test_reporter.dart`：报告新增 effectVerified / UNVERIFIED 缺口 / 跨机合并
- `ci/comprehensive-test.ps1`：入口参数（`-Mac`、`-Headless` 等）
- `docs/agent/integration-testing.md`：补焦点驱动 + 生效校验 + 跨机后台章节

## 9. 实现分期（供 writing-plans 排序，每期独立可验证）

- **Phase 1（核心价值，Android 模拟器 headless）**：focus_driver + schema_settings_verifier + effect_probes(T1/T2/T4) + `settings_schema_coverage_test`；重构两个 settings 测试。交付"焦点驱动 + 按 schema 全量 + 真生效校验"在已能跑的平台落地。
- **Phase 2（Windows 离屏后台 + T3）**：`win32_window.cpp` hidden 窗口；matrix 接 Windows 目标带 hidden 标志；桌面 T3 `getComputedStyle` 探针。**必须在用户真实 Windows 机复测**：窗口不进可视区、不抢前台、sendKeyEvent 仍驱动、前台不被打断。
- **Phase 3（Mac 跨机）**：`dispatch_mac.ps1` + reporter 跨机合并；远程 Mac 实跑 macos 场景。
- **Phase 4（收尾）**：android 委托 integration-test.sh headless 化、文档、清理。

## 10. 风险点（直说）

- **Windows 离屏渲染**：改 runner 让窗口离屏+不激活是平台边界正解、无新依赖；但 GPU/ANGLE 在离屏坐标下初始化可能异常 → 降级最小化+不激活。**声明"修好"前必须真机复测**（按 CLAUDE.md 阅读器/布局类纪律）。
- **跨机报告回传**：报告走 scp 不进 git；Mac 上 CocoaPods/ruby 钉版按 CLAUDE.local.md，构建慢但确定。
- **Sync 自定义控件**焦点语义弱 → 走"焦点到达 + 调 onChanged"降级路径，并在报告标注。
- **effect 探针长尾**：必然有设置暂无探针 → 报告逐条列 UNVERIFIED 缺口，不假装通过；按族补齐。

## 11. 验证方式

- Dart 改动：`dart format .` + `flutter test`（项目 Flutter 3.44.0 工具链）。
- Windows runner C++ 改动：`flutter build windows` + 在用户真实 Windows 机跑新 runner，肉眼确认窗口离屏/不抢前台 + 测试 PASS。
- 三端集成：新 runner 跑通并留证据（emulator headless / Windows 离屏 / 远程 Mac），报告含 effect-tier 与 UNVERIFIED 缺口清单。
- 阅读器/布局类按 CLAUDE.md：声明修好前真机复测原始失败路径并留证据路径。
