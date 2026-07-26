## BUG-1090 · 管理音频来源弹窗里已有远端 URL 无法编辑，只能删了重加
- **报告**：2026-07-25（用户：截图「设置 → 查词 → 管理音频来源」，反馈"这里没办法编辑"）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:218-272`（修复前）——
  `_buildSourceRow` 的 trailing 只给了 `Switch` / ↑ / ↓ / 删除四个控件，`remoteAudio` 行的 URL 没有任何
  写入口；`AudioSourceConfig` 本身是 `@immutable` + `copyWith(url:)` 完全支持改写，缺的纯粹是 UI 入口。
  后果：自定义查词发音 URL（尤其换机后要重指的 `localhost:5050` 这类回环源，见 TODO-1171 的换机警告）
  写错一个字符就得删掉整条、把长模板 URL 重敲一遍，且删掉重加会丢 label 与排序位置（顺序即优先级）。
- **[x] ① 已修复** — 远端行加 ✎ 编辑入口，复用下方那个 URL 输入框改写（不另开嵌套弹窗、不生第二套校验）：
  载入原 URL、`+` 变 ✓、旁边给 ✕ 取消；提交只改 `url`，`label` / `enabled` / 位置全部保留。
  编辑目标按**值身份**（`indexOf`）而非下标追踪，所以编辑中拖拽重排不会把新 URL 写到别人那行；
  删掉正在编辑的行即时清空编辑态，提交不会把它当新增复活。
  提交：见本分支 `fix(lookup): 音频来源远端 URL 可就地编辑 (BUG-1090)`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/audio_sources_dialog_page_test.dart` 新增 6 条 widget 测试：
  就地改写保留 label/enabled/位置、取消不动原值、编辑中重排仍写对行、删除被编辑行不复活、
  仅 remoteAudio 行有 ✎、✎ 占 tune 同槽位不破坏 BUG-027 的开关列对齐。全文件 18/18 绿。
- **备注**：`hibikiRemote` 行无 URL 可改、`localAudio` 行路径由文件选择器决定（已有 tune 调子来源），
  故两者都不给 ✎ —— ✎ 只出现在自定义远端行。
