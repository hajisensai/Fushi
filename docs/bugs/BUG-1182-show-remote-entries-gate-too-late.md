## BUG-1182 · 关闭「显示远端条目」仍全额拉取远端列表后丢弃

- **报告**：2026-07-28（用户：互联切页面重新拉取，排查时发现）
- **真实性**：✅ 真 bug。`showRemoteEntries`
  （`hibiki/lib/src/models/preferences_repository.dart:338`，默认 true）本意是「主网格
  不渲染远端占位卡」，但两页的门控都落在**渲染期**，取数照发不误：
  - 书架：`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:1134`
    的 `showRemote` 里才读该开关，而 `_loadRemoteBooks`
    （`reader_history/remote.part.dart:36`）无条件联网。
  - 视频页：`hibiki/lib/src/pages/implementations/home_video_page.dart:576`
    的 `_visibleRemoteVideos` 里才读，而 `_loadRemoteVideos`（同文件 `:491`）无条件联网。

  即：明确关掉远端条目的用户，每次进页面/切 tab 仍然全额付网络代价，结果直接丢弃。

  附带发现——该开关落在 `PreferencesRepository`（独立 `ChangeNotifier`，
  `preferences_repository.dart:106`），**不经 AppModel 通知**，两页都没订阅它，
  所以开关翻转后页面根本不重建，改了也要等别的原因触发重建才生效。

- **[x] ① 已修复** — 门控前移 + 补订阅：
  - 书架新增 `_shouldLoadRemoteBooks`（`reader_history/remote.part.dart`），
    `_loadRemoteBooks` 开头早退；视频页新增 `_shouldLoadRemoteVideos`
    （`home_video_page.dart`），`_loadRemoteVideos` 开头早退。关掉开关 = 一个字节都不发。
  - 两页 `initState` 订阅 `appModelNoUpdate.prefsRepo`，回调里**只**比对门控值，
    翻转才动远端 future（prefsRepo 通知频繁，不能每次都重取）。书架的翻转重取走
    build 里那段门控比对（单一路径，避免回调与 build 各重取一遍）；视频页在回调里
    直接重取。`dispose` 对称移除监听。
  - 注意用 `appModelNoUpdate` 而非 `appModel`：后者是 `ref.watch`，在 `initState`
    与非 build 回调里调用会触发「initState 完成前依赖 InheritedWidget」断言。

- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_remote_interconnect_test.dart`
  的「BUG-1182: 关闭「显示远端条目」后根本不联网（而不是拉完再丢）」：
  先 `setShowRemoteEntries(false)` 挂载，断言 `listRemoteBooksCalls == 0` 且占位卡不在场；
  再翻回 true，断言重新取数且占位卡出现（覆盖上面那条「翻转后不重建」的附带缺陷）。

- **备注**：与 [BUG-1180](BUG-1180-interconnect-remote-list-no-cache.md) 同一轮排查发现。
  首页 dashboard 的远端拉取**未**纳入本开关——该开关的语义是「库页主网格的占位卡」，
  首页的「继续」与活动流是另一套口径，扩大范围属于行为变更，不在本轮。
