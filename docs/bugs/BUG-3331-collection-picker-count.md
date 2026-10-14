## BUG-3331 · 「加入合集」弹窗的合集成员数与合集里实际显示的数量不一致
- **报告**：2026-10-14（应用内反馈 ow9_1sxU16「合集数和实际合集数量不一致」：弹窗写「10 项」，点进合集只有 6 本）
- **真实性**：✅ 真 bug。`showAddToCollectionDialog` / `pickTargetCollectionForMembers`（`fushi/lib/src/media/collections/add_to_collection_dialog.dart`，原 30–35 / 108–112 行）按 `media_collection_items` 的**原始行数**计数；合集详情页只画 `memberCardBuilder` 解析得出来的成员。成员表没有指向媒体的外键：删掉的书、配对有声书的伴生行、别的库页的条目都会留下画不出来的行，两边口径于是不一致。
- **[x] ① 已修复** — 弹窗计数改为按调用方给的可见性判据（`CollectionMemberVisibility`，`countVisibleCollectionMembers`，`add_to_collection_dialog.dart:60`）。书架把成员卡解析抽成 `_resolveCollectionMember`，详情页成员卡与新的 `_isCollectionMemberVisible` 共用它；书卡 / 字幕书卡「加入合集」与合集详情页「移到其他合集」都传入它；游戏库同理传 `_isGameCollectionMemberVisible`。不传判据的调用方保持原行为。
- **[x] ② 已加自动化测试** — `fushi/test/media/collection_picker_member_count_test.dart`（弹窗只数可见成员 / 不给判据保持原始行数 / 接线源码守卫）。
- **备注**：视频库「加入合集」与它自己的合集详情页走另一套成员解析，这次没有接判据，仍按原始行数。
