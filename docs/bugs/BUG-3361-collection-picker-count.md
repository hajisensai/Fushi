## BUG-3361 · 「加入合集」弹窗的合集成员数与合集里实际显示的数量不一致
- **报告**：2026-10-14（应用内反馈 ow9_1sxU16「合集数和实际合集数量不一致」：弹窗写「10 项」，点进合集只有 6 本）
- **真实性**：✅ 真 bug。`showAddToCollectionDialog` / `pickTargetCollectionForMembers`（`fushi/lib/src/media/collections/add_to_collection_dialog.dart`，原 30–35 / 108–112 行）按 `media_collection_items` 的**原始行数**计数；合集详情页只画 `memberCardBuilder` 解析得出来的成员。成员表没有指向媒体的外键：删掉的书、配对有声书的伴生行、别的库页的条目都会留下画不出来的行，两边口径于是不一致。
- **[x] ① 已修复** — 弹窗计数改为按调用方给的可见性判据（`CollectionMemberVisibility`，`countVisibleCollectionMembers`，`add_to_collection_dialog.dart:60`）。书架把成员卡解析抽成 `_resolveCollectionMember`，详情页成员卡与新的 `_isCollectionMemberVisible` 共用它；书卡 / 字幕书卡「加入合集」与合集详情页「移到其他合集」都传入它；游戏库同理传 `_isGameCollectionMemberVisible`。不传判据的调用方保持原行为。
- **[x] ② 已加自动化测试** — `fushi/test/media/collection_picker_member_count_test.dart`（弹窗只数可见成员 / 不给判据保持原始行数 / 接线源码守卫）。
- **备注**：视频库「加入合集」与它自己的合集详情页走另一套成员解析，这次没有接判据，仍按原始行数。
- **补漏（2026-10-16，跨域）**：上条备注里的两处已核实确有偏差并接上同一个 `isMemberVisible` 判据。
  - 视频库（`home_video_page.dart` `_addToCollection`）：视频合集详情页按 `loadCollectionEpisodeSlots` 出槽——已删视频的孤儿行、离线 / 关掉「显示远端条目」时的远端占位行、被本机同一集归并的远端副本（BUG-2978）、混合合集里的书行都不占槽，弹窗却全数。新增同步判据 `videoCollectionMemberVisibility`（`fushi/lib/src/media/collections/collection_episode_slot.dart`，与 `loadCollectionEpisodeSlots` 同文件同规则），库页用已在内存的本地全量列表 + 远端清单 + `_remoteEpisodesMirroredLocally` 喂它，远端门控与 `_collectionRemoteContext` 一致。残留口径差：库页的归并按条目的主合集分桶，同一远端集同时挂在多个合集时只在主合集里判重。
  - 游戏详情页（`galgame_detail_page.dart` `_addToCollection`）：与游戏库同一域，孤儿 game 行 / 混合合集里的非 game 行同样被多数。游戏库的私有判据抽成顶层 `isGameCollectionMemberVisible`（`games_library_page.dart`），库页与详情页共用。
  - 测试：`fushi/test/media/collection_picker_member_count_test.dart` 新增视频域在线 / 离线两例（弹窗计数 == `loadCollectionEpisodeSlots` 槽数，原始行数 6 → 3 / 2）、游戏域判据单测与两处接线源码守卫。
