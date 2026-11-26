## BUG-5513 · media-link-removal-no-undo
- **报告**：2026-11-18（来源：应用内反馈 bkrkQrYhnX，开发者自提）
- **真实性**：✅ 真 bug。「同一作品」卡片角上的「移除 AI 关联」一点就把这张卡上所有 AI 连接写成否决墓碑（`fushi/lib/src/media/links/media_links_section.dart` `_removeAiLinks` → `fushi/lib/src/media/links/work_plans.dart` `rejectMediaLinks` → `removeMediaLink`），只 toast「已移除关联」，没有撤销；否决墓碑让推断永不再提议这一对，误点后只能手动重连。卡片菜单「移除关联」、建议卡「不相关」、关系网页否决边同样没有撤销。数据层早有恢复原语 `restoreMediaLinkSnapshot`（AI 操作目录的撤销在用），UI 路径没接。
- **[x] ① 已修复** — `rejectMediaLinks` 移除前后各取一次整对的行（`removeMediaLink` 会顺带把同一对上别的 AI 生效行也写成墓碑），返回 `MediaLinkRemovalUndo`（改动行的身份 + 写入时钟 + 移除前整行），`revert` 逐行走 `restoreMediaLinkSnapshot`（之后又被改过的行不覆盖）。新增 `fushi/lib/src/media/links/media_link_removal_notice.dart` 的 `removeMediaLinksWithUndo`：移除后弹「已移除关联 · 撤销」提示条（6 秒），区块三处与关系网页否决边都改走它。新增 i18n key `media_link_restored`。
- **[x] ② 已加自动化测试** — `fushi/test/media/links/media_links_work_section_test.dart`「误点『移除 AI 关联』后点提示条的撤销，原样恢复 AI 连接」：撤销后墓碑清掉、仍是 AI 生效（不是升成用户确认）、卡片与 AI 角标回来。
- **备注**：
