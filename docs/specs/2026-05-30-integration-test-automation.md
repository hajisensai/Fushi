# 集成测试全自动化（仅模拟器）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`).

**Goal:** 一条命令跑完全部 `integration_test/*_test.dart`：自动起/选模拟器、自动备好所有前置（AnkiDroid、字典、书库），不依赖真机、不手动 `flutter drive`、不手动 adb 推送/点击。

**Architecture:** 新增编排脚本 `ci/integration-test.sh`（纯新增，零 clobber）为唯一入口：①保证有 `emulator-*` 在线（无则从 AVD 启，**只认模拟器、拒真机**）；②构建一次 debug APK；③自动 provision 外部前置（AnkiDroid 装+建库+授权、字典 zip 推 `/sdcard`）；④遍历全部 target 逐个 `flutter drive`，分类聚合 PASS/FAIL/SKIP，硬失败退出非零。书库导入类（E 类）的根因修复（测试自带 fixture）单独成 Task，受并行开发热区约束。

**Tech Stack:** bash + `D:/android_sdk/{emulator,platform-tools}` + `flutter drive` + `integration_test`。

---

## 已核实事实

- AVD：`hoshi_test` / `hoshi_test_api35`(当前在线 emulator-5554, 已装 AnkiDroid+collection) / `hoshi_test_api36` / `pixel_tablet`。emulator=`D:/android_sdk/emulator/emulator.exe`。
- 程序化导入 API（B 类已用）：`EpubGenerator().generate() -> Uint8List`；`EpubImporter.import({required HibikiDatabase db, required Uint8List bytes, required String fileName}) -> Future<int>`；导入后 `container.invalidate(hibikiBooksProvider(appModel.targetLanguage))` 刷新书架。
- **音频 cue 无静态导入 API**：只有 `AudiobookImportDialog`/`BookImportDialog`（UI）。regression 需 m4b+srt 才有 play bar，cue 程序化供给需深挖底层（Task 4 前置核实，否则 cue 子用例降级 skip）。
- 15 target 按前置分类：
  - **A 无前置/优雅降级**：`app_smoke` `settings_validation` `navigation_stability` `home_keyboard` `gamepad_navigation` `feature_flows`
  - **B 自带 fixture**：`reader_pagination` `reader_caret` `reader_popup_caret`
  - **C 需 /sdcard 字典 zip**：`popup_dictionary`（读 `/sdcard/Download/test_dict.zip`，再 `appModel.importDictionary`）
  - **D 需 AnkiDroid**：`anki_integration`
  - **E 书架空则硬 fail()**：`regression`(+音频) `user_path` `reader_dictionary`(+字典) `reader_keyboard`
- **热区铁律**：`integration_test/` 并行开发极活跃（最近 8 提交全是 reader/dict 测试），当前未提交=`reader_caret_test.dart`。E 类里 `reader_dictionary` 是高冲突候选 → Task 4 优先碰 `regression`/`user_path`/`reader_keyboard`，`reader_dictionary` 视实时 git 状态决定碰不碰。
- 约束：`flutter drive` 每 target 收尾卸载 app，数据不跨 target 持久化 → E 类自动化唯一干净路径是测试内自带 fixture（不能靠脚本预导入）。

---

## File Structure

- `ci/integration-test.sh`（新增）唯一入口：模拟器保障 + 构建 + provision + 遍历 + 聚合。
- `ci/lib/provision-ankidroid.sh`（新增）把 `ci/anki-integration-test.sh` 的 AnkiDroid provision 抽出，两脚本 `source`（DRY）。
- `integration_test/helpers/library_fixture.dart`（新增，Task 4）：`seedReaderBook(tester)`（复用 EpubGenerator+EpubImporter）/ `seedDictionary(appModel)`（`/sdcard` zip 真实导入）/ 尽力 `seedAudioCues`（取决于底层 API）。
- `CLAUDE.md`：把过时 `test-flows.ps1` 段替换为 `ci/integration-test.sh`。
- E 类测试文件：Task 4 仅动非热区 `regression`/`user_path`/`reader_keyboard`。

---

## Task 1: 脚本骨架 + 模拟器保障（拒真机）+ 构建 + 预装

**Files:** Create `ci/integration-test.sh`

- [ ] Step 1: 头/参数/工具发现；`emulator_serial()` 用 `adb devices | awk '/^emulator-[0-9]+\tdevice$/'` 只挑模拟器；无则 `emulator -avd $AVD -no-snapshot-save -gpu host &` 等 `sys.boot_completed=1`。`set -uo pipefail`（非 -e）。
- [ ] Step 2: `flutter build apk --debug`（除非 `--skip-build`）；`adb -s $DEVICE install -r -g $APK`（-g 保留 AnkiDroid 授权）。
- [ ] Step 3: 验证 `bash ci/integration-test.sh --only app_smoke`（先临时 `exit 0` 桩）：打印选中的 emulator-5554 + booted。
- [ ] Step 4: Commit `test(ci): integration runner — emulator-only boot/guard + build`

## Task 2: provision AnkiDroid + 字典 zip

**Files:** Create `ci/lib/provision-ankidroid.sh`; Modify `ci/integration-test.sh`, `ci/anki-integration-test.sh`

- [ ] Step 1: 把 anki-integration-test.sh 的 provision（装 AnkiDroid/建 collection/grant/校验 granted=true）抽到 `ci/lib/provision-ankidroid.sh` 的函数，两脚本 `source` 调用。
- [ ] Step 2: integration-test.sh 推字典：`DICT_ZIP` 存在则 `MSYS_NO_PATHCONV=1 adb push "$DICT_ZIP" /sdcard/Download/test_dict.zip`，否则 WARN（popup_dictionary 将 fail，如实报告）。
- [ ] Step 3: 验证 `--only popup_dictionary,anki_integration --skip-build` 两绿。
- [ ] Step 4: Commit `test(ci): shared AnkiDroid provision lib + dictionary fixture`

## Task 3: 遍历全部 target + 分类聚合 + 退出码

**Files:** Modify `ci/integration-test.sh`

- [ ] Step 1: `ALL_TARGETS=(...15...)`；`--only=a,b` 过滤；`run_target()` 跑 `flutter drive ... --target=... -d $DEVICE`，日志 grep `All tests passed` 分 PASS/FAIL，缺文件 SKIP。
- [ ] Step 2: SUMMARY 打印 PASS/FAIL/SKIP 列表 + 每类计数；`[ ${#FAIL[@]} -eq 0 ] && exit 0 || exit 1`。
- [ ] Step 3: 全量 `bash ci/integration-test.sh` 验证：A/B/C/D 绿；E 类（未做 Task4）FAIL 且日志显示 `fail('... import ... first')`（真实未覆盖，不掩盖）。
- [ ] Step 4: Commit `test(ci): run all integration targets with classified summary`

## Task 4（受热区约束的根因修复）: E 类自带 fixture

**Files:** Create `integration_test/helpers/library_fixture.dart`; Modify `regression`/`user_path`/`reader_keyboard`（`reader_dictionary` 仅当其非热区时）

- [ ] Step 1: 前置核实底层 cue 写入 API（hibiki_audio/database），能调则 `seedAudioCues`，否则 regression 的音频子用例标注 skip。
- [ ] Step 2: `library_fixture.dart`：`seedReaderBook` 复用 EpubGenerator+EpubImporter+invalidate；`seedDictionary` 用 `/sdcard` zip。
- [ ] Step 3-4: 把各 `if (empty) fail(...)` 换成 `await seedReaderBook(tester)` 后重查；逐个 `flutter drive` 验证转绿。
- [ ] Step 5: Commit `test(reader): self-provision library fixture (regression/user_path/reader_keyboard)`

## Task 5: 文档

- [ ] CLAUDE.md：过时 `test-flows.ps1` 段 → `ci/integration-test.sh` 入口；commit。

---

## Self-Review
- 覆盖：仅模拟器✅(T1 guard) 全自动一命令✅(T1-3) AnkiDroid/字典/书库前置✅(T2/4)。
- 风险：①T4 触 reader 测试热区 + 音频 cue API 未确认（T4S1 前置核实）；②单 AVD 串行 15 target 慢（正确性优先，可接受）。
- 不做：不 DB-seed 假数据替代真实导入；不合并成单 target（state-bleed）。
