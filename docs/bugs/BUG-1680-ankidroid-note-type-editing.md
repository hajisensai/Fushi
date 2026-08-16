## BUG-1680 · AnkiDroid 能改已存在 note type，Lapis 样式区却在手机上整区隐藏
- **报告**：2026-08-16（用户：手机看不到 lapis 卡片样式）
- **真实性**：✅ 真 bug（建立在错误的平台前提上）。根因 `packages/fushi_anki/lib/src/base_anki_repository.dart:222` 的默认 `supportsNoteTypeEditing => false` + `AnkiRepository`（AnkiDroid）从不覆写它，设置页 `fushi/lib/src/pages/implementations/anki_settings_page.dart:142` 据此把整个 Lapis 样式区隐藏。

  代码注释把这写成「平台边界，非本仓可修」，但那是错的：AnkiDroid 上游 `CardContentProvider.update()` 的 `models/<mid>` 分支支持写 `FlashCardsContract.Model.CSS`，`models/<mid>/templates/<ord>` 分支支持写 `CardTemplate.QUESTION_FORMAT` / `ANSWER_FORMAT`；被明确拒绝的只有改字段名（`"Field names cannot be changed via provider"`），而 Lapis 样式客制化一个字段名都不改。`fushi/android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java` 只实现了 `createNoteType`，从没实现读/改——「我们没实现」被记成了「平台做不到」。

  真正的平台边界是 iOS 的 `AnkiMobileRepository`（只有加卡的 URL scheme），它仍然降级。
- **[x] ① 已修复** — `AnkiChannelHandler.java` 新增 `readNoteType` / `updateNoteTypeStyling` / `updateNoteTypeTemplates` 三个 method（走 ContentProvider；模板按**名字**而不是 ord 匹配——ord 是位置，用户重排模板之后按位置写回会把正面写进另一张卡）；`packages/fushi_anki/lib/src/ankidroid/anki_repository.dart` 覆写 `supportsNoteTypeEditing => true` 与三个读写方法。
- **[x] ② 已加自动化测试** — `fushi/test/anki/ankidroid_note_type_editing_test.dart`：MethodChannel 行为测试（读解析 / 写 payload / 空列表不打桥 / 桥返回 false 不谎报成功）+ Java 桥源码扫描守卫（三个 case 分支、写入用的是 provider 真正认的列、不把字段名塞进 ContentValues）。守卫已变异实测：把 `case "readNoteType":` 改名后测试转红，还原后文件 sha256 与变异前一致。
- **备注**：与 BUG-1681 / BUG-1682 同批（同一条「手机上两块 Anki 维护功能看不到」的用户报告）。真机验证仍缺：需要在装了 AnkiDroid 的 Android 机上跑一次「改字号 → 应用样式到 Anki → 卡片真的变了」。
