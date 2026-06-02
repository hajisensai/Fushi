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
- **禁止通过截图猜坐标点击 UI 元素。** 如果必须通过 ADB 点击（而非 `flutter drive`），先 `uiautomator dump` → 解析 XML 找 `content-desc`/`text` 匹配的元素 → 从 `bounds` 算中心坐标 → `input tap`。辅助脚本：`.codex-test/tools/tap-element.sh <content-desc>`、`.codex-test/tools/list-elements.sh`。
- **ADB 路径固定用** `D:/android_sdk/platform-tools/adb.exe`，不依赖 PATH 中的 adb。
- 需要新增测试流程时，先判断属于哪一层，不要在错误的层做事。
- 不要在同一台模拟器上并发跑两个编排脚本——日志会互相污染。

## 一键运行（全自动，仅模拟器）

集成测试的唯一入口是 `ci/integration-test.sh`：自动选/启一台模拟器（物理真机会被忽略），构建一次 debug APK，自动 provision 所有前置（AnkiDroid 安装+建 collection+授权、字典 zip 推 `/sdcard`），再遍历全部 `integration_test/*_test.dart` 目标逐个 `flutter drive`，最后打印分类 PASS/SKIP/FAIL 汇总（任一失败退出非零）。

```bash
bash ci/integration-test.sh                      # 起/选模拟器，构建，provision，跑全部目标
bash ci/integration-test.sh --skip-build         # 复用已构建的 app-debug.apk
bash ci/integration-test.sh --only=app_smoke,reader_pagination
bash ci/integration-test.sh --avd=hoshi_test_api35
```

每个目标的日志落在 `.codex-test/itest-logs/<target>.log`。

当前 `integration_test/` 下共 **18** 个 `*_test.dart` 目标：`anki_integration`、`app_smoke`、`comprehensive_imports`、`comprehensive_reader_lookup`、`comprehensive_settings`、`feature_flows`、`gamepad_navigation`、`home_keyboard`、`navigation_stability`、`popup_dictionary`、`reader_caret`、`reader_dictionary`、`reader_keyboard`、`reader_pagination`、`reader_popup_caret`、`regression`、`settings_validation`、`user_path`。

书库依赖类测试（`reader_dictionary` / `reader_keyboard` / `regression`）通过 `integration_test/helpers/library_fixture.dart` 在测试内自带 fixture：`seedReaderBook` 用 `EpubGenerator`+`EpubImporter` 程序化导入合成 EPUB，`seedDictionary` 导入 runner 推到 `/sdcard/Download/test_dict.zip` 的字典。因此在全新安装上也无需手动导入。

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

## 测试素材（仓库外，不入库）

固定测试资料放仓库外固定路径，不纳入 git（`.codex-test/` 整体 gitignored）；临时截图、UI XML、logcat 片段放 `.codex-test/` 下，并在最终回复里给出具体路径。

| 类型 | 路径 |
|------|------|
| EPUB | `.codex-test/fixtures/kagami/かがみの孤城 (辻村深月) (Z-Library).epub` |
| 音频 | `.codex-test/fixtures/kagami/かがみの孤城 [audiobook.jp 244083].m4b` |
| 字幕 | `.codex-test/fixtures/kagami/かがみの孤城 [audiobook.jp 244083].srt` |
| 字典 | `D:\辞典\` 目录下任意 `.zip` |

`D:\辞典\` 可用字典清单：
- `明镜日汉双解词典_Yomitan 1.4.4.zip`
- `[JA-JA] 日本語俗語辞書.zip`
- `[JA-JA] 実用日本語表現辞典.zip`
- `[JA Freq] BCCWJ_SUW_LUW_combined.zip`
- `[JA Freq] JPDB_v2.2_Frequency_Kana_2024-10-13.zip`
- `どんなときどう使う 日本語表現文型辞典_1_05.zip`
- `[JA-JA] 明鏡国語辞典 第三版[2025-08-18].zip`
- `（大修館）明鏡国語辞典［第二版］.zip`
- `Nihongo-Bunkei-Jiten.zip`
- `[JA-JA] ことわざ・慣用句の百科事典.zip`
- `[JA-JA] 絵でわかる慣用句 [2024-06-30].zip`
- `[JA-JA Expressions] 故事ことわざの辞典.zip`
- `[JA-JA Grammar] [画像付き] 絵でわかる日本語 v3.zip`
- `大辞泉/大辞泉 第二版[2025-04-29][no-images].zip`
- `大辞泉/大辞泉 第二版[2025-04-29].zip`
- `旺文社国語辞典 第十二版/旺文社国語辞典 第十二版[2025-04-29].zip`
- `小学館 例解学習国語 第十二版/小学館例解学習国語 第十二版[2025-08-18].zip`
- `[Pitch] NHK日本語発音アクセント新辞典.zip`

推送到模拟器时可改成 ASCII 文件名，避免 Windows/adb 对日文文件名抽风（如 `/sdcard/Download/hibiki-test/kagami/kagami.epub`）。大文件推送后必须用 `adb shell ls -lh` 确认大小，不要只信 `adb push` 的一行输出。

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
