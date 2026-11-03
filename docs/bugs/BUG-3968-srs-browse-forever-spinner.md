## BUG-3968 · srs-browse-forever-spinner
- **报告**：2026-11-02（用户：反馈 pD2oUIn6rP「删除卡片没有及时删除，出去再进一直加载」）
- **真实性**：✅ 真潜在缺陷（与反馈主因并存）。反馈主因（删除慢、重进长读排队）在存储层，由 BUG-3959 / BUG-3961（PR #2770 / #2771）修；这里修页面层的「永远转圈」结构：`fushi/lib/src/pages/implementations/srs/srs_browse_page.dart:191` 的 `_refresh` 不收口异常（`_compute` 抛出 `SrsSearchUnsupported` / `SrsBrowseResultGone` 以外的异常时 `_loading` 永远为 true），库不可用（`readSrsStore` 返回 null）时直接 return 也留在加载态；`:275` 对 `SrsBrowseResultGone` 无上限递归重查。牌组列表 `srs_deck_list_page.dart` `_buildBody` 在 provider 读完但值为 null（模块关 / 库不可用）时同样永远转圈。
- **[x] ① 已修复** — 浏览页加显式出错状态 `_loadError`（出错占位 + 重试，重试在库没打开时连库一起重开），`_refresh` 全程收口异常并记日志、按代号丢弃过期结果；换库时注销旧会话；`SrsBrowseResultGone` 改为最多重查一次（重查让原生侧重建会话 / 结果），连续两次即转出错状态。牌组列表值为 null 时显示「引擎不可用」+ 重试。复习页 `_start` / `_loadNext` 已有收口（store null → `_error`，异常 → `_error`），无需改。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_builtin_restore_and_load_error_test.dart`（库打不开 / 库为 null / 查询中库已关 三种都落到出错占位而非加载态）。
- **备注**：同款「store == null 直接 return」还出现在不归本组的 `srs_browse_preview.dart:130`、`srs_conflicts_page.dart:102`、`srs_edit_history_page.dart:57` 等页面加载入口，未改，需另行审计。
