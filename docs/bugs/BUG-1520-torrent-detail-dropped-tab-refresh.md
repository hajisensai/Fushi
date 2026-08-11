## BUG-1520 · 下载详情切换标签时Tracker刷新被丢弃
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。当前恢复目录中的 7 个 torrent 均持久化了 5 条 Nyaa Tracker，同一打包 DLL 的 `ht_torrent_trackers` 也能逐个返回这 5 条；数据链正常。根因在 `fushi/lib/src/pages/implementations/torrent_detail_dialog.dart:147`：任一刷新进行中时，切换标签触发的 `_refresh` 被 `_refreshing` 直接丢弃，没有记录待刷新标签，导致节点请求未结束时切到 Tracker 会一直保留未加载状态。
- **[x] ① 已修复** — 刷新占用时记录最新请求标签；当前轮结束后若标签已变化，立即补跑该标签的数据请求。相同标签的周期轮询仍合并，避免慢后端造成无界刷新循环。
- **[x] ② 已加自动化测试** — `fushi/test/pages/torrent_detail_dialog_test.dart` 用受控延迟节点后端覆盖“节点请求中切换 Tracker”，断言节点完成后 Tracker 查询必定补跑并渲染。
- **备注**：按用户要求跳过自动化测试，使用 Windows Debug 构建直接实测。
