## BUG-872 · 互联远端视频看完返回即重拉列表
- **报告**：2026-07-18（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/home_video_page.dart:221`（原 `_refresh()` 无条件 `_remoteFuture = _loadRemoteVideos()`）。从播放器返回走 `_open()`（`:1057` `_refresh()`）→ `_refresh` 连带重换远端 future → 远端那层 `FutureBuilder`（`:1662`）无缓存顶值，future 一换 `snapshot.data` 变 null → `_visibleRemoteVideos` 返回空 → 远端卡整片闪空重拉。远端清单不因本地播放而变，此重拉纯属多余（`_refresh` 自身注释也承认「切回 tab 不再隐式重拉远端，pull-to-refresh 才是显式刷新入口」，却在本地路径重拉了）。
- **[x] ① 已修复** — 给 `_refresh({bool remote = false})` 加开关，默认只刷本地；仅 `_openManageSources`（改变远端来源）传 `remote: true`。远端显式刷新仍由下拉 `_pullToRefresh` 承担。提交见 PR。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/home_video_refresh_remote_guard_test.dart` 源码扫描守卫：`_refresh` 的远端重拉必须门控在 `remote` 之后，`_open` 返回后的刷新必须是本地 `_refresh()`（无 `remote: true`）。
- **备注**：与 BUG-750/PR#53（切 tab keepAlive）不同源——那修的是 tab 切换销毁重建，本 bug 是从播放器返回的 `_refresh` 主动换 future。
