## BUG-3491 · 视频剧集进度返回不刷新、重看已看集续播跳下一集、自动标记看完判定不一致
- **报告**：2026-10-17（用户：应用内反馈，Android vivo，2.10.0-debug.19358；剧集列表截图：11 集打勾、12 集高亮「看到 19:35」、13 集无进度）
- **真实性**：✅ 真 bug（四点逐条沿代码路径核实，基线 `42f8912c6a`）
  1. **返回剧集页进度不刷新**：合集详情页的成员进度是 `_reload()` 一次读出的快照，只在 `initState` 调一次（`fushi/lib/src/pages/implementations/media_collection_detail_page.dart:273`）；开集 `_openSlot`（同文件 `:1537`）只是 fire-and-forget 地 push 播放页，回来没有任何失效 / 重读。不能靠 `await Navigator.push`：播放页内换集走 `pushReplacement` / `removeRoute`（`video_fushi/episode.part.dart` `_switchEpisode`），第一集被换走时那个 Future 就完成了。媒体服务器详情页同病（`media_server/media_server_detail_view.dart:288` `_playEpisode` 播完不重拉，播放出口 `MediaServerPlayHandler` 是 `void`）。
  2. **重看已打勾的集续播跳下一集**：`continueMemberIndex` 锚点已完成就推进（`fushi/lib/src/media/collections/collection_continue.dart:72`），首页「继续观看」同口径（`fushi/lib/src/media/video/video_home_layout.dart:318`）。而打勾是一次性事实（`markVideoCompleted` 只在 `completed_at IS NULL` 时写，重看不撤销），所以「重看第 12 集看到一半退出」与「第 12 集看完了」在数据上不可区分——库里没有片长，分不出断点是不是在片尾。
  3. **自动打勾时机随机**：完成判定（≥ 90%，`shouldMarkCompleted`）只挂在 `StudyClock` 每 60 秒一次的 tick 上（`fushi/lib/src/media/video/video_watch_tracker.dart:122`）；离开本集时那一次判定（`:165`）排在 `await _clock.stop()` 之后，而 `dispose()` 调完 `unawaited(stop())` 立刻 `_source = null`（`:180-182`），`_checkCompletion` 看到 `_source == null` 直接返回——**离开时的判定永远落空**。于是：跳到 ED 立刻点下一集不打勾（60 秒内没有 tick）；暂停态拖进度条预览恰好赶上 tick（位置 ≥ 90%）就莫名打勾。
  4. **想要百分比**：集卡在算得出百分比时只画进度条、不写文字，算不出时只写「看到 mm:ss」；已打勾的集连时间进度都不显示（`collection_detail_layout.dart` `CollectionEpisodeCard`）。截图里第 12 集只有「看到 19:35」就是因为没有刮削片长。
- **[x] ① 根因修复** — `3b9fb795bd`
  - 详情页按「本页路由重新成为栈顶」判回来（`ModalRoute.of(context).isCurrent` 边沿，`didChangeDependencies`），只在本页派出过播放（`_openSlot` 置位）时重读，对话框 / 菜单关掉不重读。媒体服务器播放出口改为返回 Future（`FutureOr<void>`，生产 = 根 Navigator push 的 Future，那条路由不会被 pushReplacement），详情页播完原地重拉已加载的集（不清空、不动滚动）；电影重取详情。
  - 播放器第一次落断点时把**真实片长**记进偏好 `video_duration_ms_<uid>`（`video_duration_pref.dart`，与断点镜像键 / 覆盖并集键同一种「每视频一个偏好」形态，不动 schema）。`CollectionMemberProgress` 加 `durationMs`：已打勾且断点不在片尾区（`isEpisodePositionNearEnd`，与打开时「从头放还是续播」**同一判据**）= 正在重看（`isRewatching`），续播停在它。不知道片长（旧库 / 没在本版本播过）一律沿用旧口径推进——旧库里看完的集断点都停在片尾附近，分不出来时宁可不改行为。详情页 / 首页继续观看 / 下一集 / 合集卡进度 / dashboard 视频合集 / 首页合集直开六处同一判据；远端集用 host / 服务器下发的 `durationMs`。
  - 完成判定改为：播放中每个位置采样点（1 秒 + 播放源通知）判一次，离开时按**离开那一刻同步取下的位置**再判一次；不再挂在 60 秒 tick 上。规则：**播放到 90% 之后，或停在 90% 之后离开，即打勾；暂停态拖条预览不算**。阈值 90% 不变。
  - 集卡：有断点就写「看到 mm:ss」（已打勾的集在对勾旁照样写），知道片长时接「· NN%」；进度条仍只画在未看完的集上。媒体服务器集行同样接百分比。
- **[x] ② 自动化测试** — `fushi/test/media/collection_continue_test.dart`（BUG-3491 组：重看停留 / 片尾推进 / 3 秒尾巴 / 无片长旧口径 / 真值表）、`fushi/test/media/video/video_watch_tracker_test.dart`（自动标记看完的时机：dispose 离开时打勾 / 播放中越过 90% 立即打勾 / 暂停拖过 90% 再拖回不打勾）、`fushi/test/pages/collection_detail_progress_refresh_test.dart`（播放页退回即刷新、普通路由退回不重读、重看停在第 1 集、无片长推进、已打勾集保留时间进度 + 百分比）、`fushi/test/pages/media_server/media_server_detail_view_test.dart`（播放页退回原地重拉 + 百分比）。
- **备注**：
  - 来源覆盖：本地视频（主路径，全部四点）；互联远端集（同一详情页，回来会重读，但远端清单走 `RemoteLibraryCache`，TTL 内可能还是旧的 host 进度；完成标记以 host 为准，本机不写）；媒体服务器（①④；已看标记由服务器自己的规则决定，本机只上报进度——退回时重拉与播放页 stop 上报是并发的，极端情况下可能拿到上报前的数据）；在线源（Aniyomi）详情页本来就在播完后重算续播落点（`anime_source_detail_page.dart` `_reloadResumeIndex`），它没有逐集进度 / 打勾展示，不在本次范围。
  - 未在真机上复测原始路径（Android vivo）；验证为单测 + widget 测试。
  - 待拍板：是否取消「自动打勾」只显示百分比（反馈第 ④ 条建议）——本次不改，保留 90% 自动打勾。
