## BUG-2982 · 漫画章节列表以下载状态作身份导致重复 sibling key
- **报告**：2026-10-06（用户要求全面审查修复）
- **真实性**：真实代码路径缺陷，样式提交 `bc6bca9a161` 引入。固定审查快照为 `1a5424c847a`。
- **根因**：`fushi/lib/src/media/manga/library/manga_chapter_list.dart:275` 原先把 `manga_chapter_download_${download.name}` 作为 Column 直接子节点的 key；多章同下载状态会使用重复 sibling key，章节排序及状态更新时也没有稳定章节身份。
- **[x] ① 已实现修复** — 外层使用 `chapter.key` 保持章节身份，下载状态探针移到各行内部。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/media/manga/manga_chapter_identity_test.dart`：多个同状态章节、排序及下载状态改变后保留章节 State。
- **验证结果**：见 [审查报告 HBK-AUDIT-010 及最终验证记录](../reviews/2026-10-06-project-review.md)。本条记录实现与测试覆盖，不将未完成或失败的测试轮次视为通过。
- **备注**：真实设备的漫画详情页验收待补；不覆盖 CC 在审查快照之后的修改。本号原先汇总多类问题，现按一 bug 一文件规则收敛为漫画章节身份问题，保留原文件名及编号。
