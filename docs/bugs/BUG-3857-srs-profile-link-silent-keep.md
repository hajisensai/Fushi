## BUG-3857 · 多台设备同名 profile 静默不关联、冲突只闪 toast
- **报告**：2026-10-28（用户：iPhone 弹「无法自动关联」toast，至少应该弹窗；平板拉不到电脑的复习数据、显示 0/0/0）
- **真实性**：✅ 真 bug。三台设备各自随机生成 profile uid、都叫 Default。`packages/fushi_engine/lib/srs/srs_profile_link.dart` `srsDecideProfileLink`：按名字匹配到 >1 个候选时直接 `return SrsProfileLinkKeep()`（平板永远按自己的空 profile 同步，无任何提示）；两边都有笔记时只回 `SrsProfileLinkConflict`，app 侧每进程一条 toast（`srs_app_runtime.dart` `_showSyncNotice`），没有任何处理入口；判定每轮把整个命名空间列一遍。
- **[x] ① 已修复**（4dc4c418ef）— 判定只把有数据的同一 profile 当候选：唯一且本机空 → 自动采用；多个候选或两边都有笔记 → `SrsProfileLinkChoose`，进复习页时弹窗让用户选采用哪一份 / 保持本机独立 / 稍后；本机有笔记时并入所选 profile（`srs_profile_merge.dart`，只对 uid 派生的内置 ID 做映射），不丢任何一边；本设备改用别的 uid 后留下的孤儿目录自动清掉；冲突判定 30 分钟内复用、已关联永久复用。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_profile_link_test.dart`（按实测三设备布局的平板 / iPhone / 电脑视角用例）、`packages/fushi_engine/test/srs/srs_profile_merge_test.dart`。
- **备注**：并入是铁律 E「不做任何 ID 重映射」的限定例外（仅 uid 派生的内置牌组 / 笔记类型 / 字段 / 模板 ID）。未在真机复测。
