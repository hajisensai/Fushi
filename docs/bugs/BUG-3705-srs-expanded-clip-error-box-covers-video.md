## BUG-3705 · 复习卡片段「放大查看」被错误盒整块盖住，关闭键缺失
- **报告**：2026-10-23（来源：任务 P 真机验证「卡面与对话框同时挂同一个 media_kit 画面是否正常」；Windows 离屏 runner）
- **现象**：复习页点片段角上的「放大」，对话框里的画面整片偏红（debug 构建；release 下应为灰色错误盒），右上角关闭键不出现，只能点外面关。图层截图与 OS 级 `PrintWindow(PW_RENDERFULLCONTENT)` 一致，不是截图伪影。
- **真实性**：✅ 真 bug，且与「同一个画面挂两次」无关：`integration_test/media_kit_dual_view_probe_itest.dart` 里同一个 VideoController 在普通页面双挂（大 / 小、裸 Texture、d3d11va 硬解）颜色全部正常；改走 `showAppDialog` + `SrsCardVideoExpandedView` 立即复现（对话框区域 RGB 均值 132/9/6）。根因：`fushi/lib/src/pages/implementations/srs/srs_card_video_clip.dart` `SrsCardVideoExpandedView` 的关闭键 `FushiIconButton`（内含 `InkWell`）要求 Material 祖先，`showAppDialog` 推的对话框路由内容下没有 Material，构建抛 `No Material widget found`（error_log 里有完整栈），该子树被 `ErrorWidget` 替换；错误盒在 `Positioned(right: 0, top: 0)` 里拿到宽松约束、按最大尺寸铺满整个放大画面，把视频盖住。
- **[x] ① 已修复** — 待提交（分支 claude/srs-feedback-triage-846294）：放大视图自带 `Material(type: MaterialType.transparency)`（只提供墨水层，不画东西）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_card_video_expanded_view_test.dart`（真实 `showAppDialog` 路由：无异常、无 ErrorWidget、画面在、点画面切换播放、关闭键可关；去掉修复变异实测红）
- **备注**：同一个 controller 在卡面与对话框同时挂两个 `Video`（同一纹理 id 画两遍）本身实测正常；关掉对话框后卡面画面正常。其它经 `showAppDialog` 直接放 InkWell 系控件、不经 Dialog / Material 的调用点未逐一排查。
