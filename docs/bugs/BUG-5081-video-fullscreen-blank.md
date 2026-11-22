## BUG-5081 · video-fullscreen-blank
- **报告**：2026-11-21（用户：录屏 QQ20261121-183725，Windows 3.4.0-debug.30416 本地视频一全屏整窗只剩底色，控件也没有，再按一次退出才恢复）
- **真实性**：✅ 真 bug，Windows 离屏集成测试稳定复现（全屏后树里 `Video` 数 = 0）。根因 `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart` 的 `_videoWithSubtitlePanel`：拍板台 P9AS-fvjJh（99c11d60a7f）为竖屏学习版式搬家保留画面身份，给画面包了 `KeyedSubtree(key: _videoSurfaceKey)`；而窗口侧与全屏路由（`fullscreen.part.dart` `_pushNeutralizedVideoFullscreen`）都调这个 helper。全屏路由压上时窗口页仍挂载（maintainState），同一个 GlobalKey 同时出现在两个宿主里，element 被抢来抢去，两边都没有 `Video`，只剩全屏路由 `Material` 的 surface 底色。
- **[x] ① 已修复** — helper 改为显式 `surfaceKey` 参数：只有窗口宿主传 `_videoSurfaceKey`，全屏路由传 null（全屏只在桌面出现、不会切竖屏版式，无需跨版式保留身份）。
- **[x] ② 已加自动化测试** — `fushi/integration_test/video_fullscreen_blank_test.dart`：真 app 开本地视频 → F 进 runner 原生全屏 → 断言台上恰一个 `Video` 且有尺寸、无框架异常，Esc 退出后窗口侧 `Video` 仍在。
- **备注**：PR 见提交记录。
