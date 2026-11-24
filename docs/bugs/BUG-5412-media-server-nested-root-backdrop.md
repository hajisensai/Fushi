## BUG-5412 · 视频库「媒体服务器」分区：Apple 设计下白底遮住壁纸，Material 下缩放闪动
- **报告**：2026-11-24（用户：应用内反馈 vhFvt3IkHm，Windows / 3.4.0-debug.32193，附两张截图）
- **真实性**：✅ 真 bug。截图：「全部视频」分区露出自选壁纸，切到「媒体服务器」分区后顶栏以下整块白底。根因 `fushi/lib/src/pages/implementations/media_server/media_server_browse_page.dart:238-248`（修前）分区内嵌 `Navigator` 的根路由（服务器列表）也用 `adaptivePageRoute` → `MaterialPageRoute`，它的转场查主题，主题的每个平台 builder 都包着 `FushiBackdropPageTransitionsBuilder`（`fushi/lib/src/models/theme_notifier.dart` `pageTransitionsTheme`），于是分区里垫了**第二层** `FushiPageBackdrop`（`fushi/lib/src/utils/adaptive/fushi_page_backdrop.dart`）：
  - 自选图片在分区范围内按分区尺寸重画一遍：`BoxFit.cover` 裁切与外层不同、自带一份缓慢漂移缩放（`page_backdrop_layer.dart` `_content` 的 `Transform.scale`），模糊档按新尺寸重新烘焙、烘焙完再淡入（`prebaked_blur_image.dart` `AnimatedOpacity`）——Material 下看到的「缩放闪动」。
  - 遮罩（页面底色 × scrim + 顶部渐隐）叠两层，烘焙完成前图片层为空；并按首次挂载时的模块重新发布背景作用域（`FushiPageBackdrop.activeOf` 决定页面底色透不透明）——Apple 设计（白色 surface）下分区整块发白、盖住壁纸。
  - 分诊初判里「Windows 走 Zoom 转场」不成立：Windows 的 Material 转场早已是 `FushiSharedAxisPageTransitionsBuilder`，且初始路由本就不播进场动画；「Cupertino 路由画不透明底色」也不准确（Apple 设计走 MaterialPageRoute + 主题转场，隐藏的 cupertino 设计系统才走 CupertinoPageRoute）。真正的问题都来自那层多垫的背景。
- **[x] ① 已修复** — 新增 `mediaServerNestedRootRoute`（同文件）：嵌套根页改用不读主题转场的 `PageRouteBuilder`（`opaque: false`、进出时长 0），页面直接叠在外壳页已画好的背景上、沿用外壳页的背景作用域；往后推进来的网格 / 详情（`media_server_routes.dart`）要盖住下面那页，照旧用 `adaptivePageRoute`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_server/media_server_browse_page_test.dart`「嵌套根页透明、无进场过渡、不再垫第二层页面背景」（真实主题 `buildFushiFallbackTheme`，Windows / iOS 两个平台各一遍：全树只有外层 home 路由一层 `FushiPageBackdrop`、分区子树里没有；根路由 `opaque == false`、进出时长 0）。
- **备注**：未在 Windows 真机复测像素（需要用户自选背景图片 + 切 Apple / Material 两套设计）。分区内**推进来**的网格 / 详情页仍按普通页垫自己的背景层（要盖住下面那页），同一张图在分区尺寸内重画一次，烘焙按尺寸缓存、只在首次有淡入；若这一层也要与外壳完全对齐，需要另想「嵌套栈里的不透明页」方案，未在本次处理。
