## BUG-3854 · 内置 AI 助手怎么都做不到「关联作品」
- **报告**：2026-10-27（用户：群聊反馈，让 AI 把《向山进发》的特典 CD 与动画关联，「怎么都做不到」）
- **真实性**：✅ 真 bug（沿真实代码路径确认）。AI 能调的作品图谱操作只有 `links.list` / `links.accept` / `links.reject` / `links.infer`（`fushi/lib/src/ops/op_descriptions_media_links.dart`、`fushi/lib/src/ops/ctl_media_links_routes.dart`），全是围着**推断出的建议**转的：
  - 详情页「关联作品」对话框背后的手动连接（`upsertManualMediaLink`，`fushi/lib/src/media/links/media_link_editor_dialog.dart` 的 `_pick`）从来没进操作目录，用户点名「把 A 和 B 关联起来」时没有任何操作能写；
  - `links.infer` 对音乐条目直接拒绝（「音乐条目没有推断来源」），推断也不会凭空给出用户想要的那一对；
  - 也没有任何操作能按标题查出另一端的 `<kind>:<key>` 端点（音乐专辑 / 视频合集的键 AI 无从得知）；
  - 已确认的关联也不能移除（`links.reject` 只收建议，报错让用户去详情页长按）。
- **[x] ① 已修复** — 把对话框的写入抽成共享的 `writeManualMediaLink`（`fushi/lib/src/media/links/media_link_manual.dart`，对话框与 AI 同一条路径），新增三条操作：`links.candidates`（按种类 + 标题查本机条目拿端点，含 `music_album`）、`links.add`（adaptation / same_work / theme_song，参数校验与对话框一致，adaptation 要求说明方向）、`links.remove`（移除已确认的关联）。两条写操作可撤销：数据层新增对称方法 `restoreMediaLinkSnapshot`，把这一行恢复成执行前的整行快照（执行前没有就写墓碑、不删行，防同步拉回）；执行后用户又改过（`updatedAt` 变了）报 superseded、不覆盖。
- **[x] ② 已加自动化测试** — `fushi/test/ops/op_undo_media_links_test.dart` 新增「手动关联」组：候选查找、改编方向、把建议手动连上后撤销恢复原建议、用户事后移除时撤销 superseded、same_work 无方向、非法参数（缺方向 / 主题曲两端不对 / 不可手动的关系 / 不在库的端点）拒绝且不写库、移除确认关联与撤销恢复（保留 createdAt）、建议不能当关联移除。`op_catalog_ratchet_guard_test.dart` 的地址参数豁免表登记两条新操作（endpoint 是本地条目引用）。
- **备注**：未在真机上用实际 LLM 跑一遍对话（只验证了操作层）；特典 CD 这种「OST 专辑 → 动画」用 `same_work` 连，`soundtrack` 关系与 UI 一致仍不开放手动连接。
