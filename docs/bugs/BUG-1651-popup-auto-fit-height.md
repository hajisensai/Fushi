## BUG-1651 · 查词弹窗忽略内容高度导致底部大面积留白
- **报告**：2026-08-14（用户：视频查词弹窗底部出现大面积空白）
- **真实性**：✅ 真 bug。`popup.js::_reportPopupHeight` 已把 DOM 内容高度放在
  `popupRendered` 的第一个参数上报，但 `dictionary_popup_webview.dart` 只读取 render
  token；`dictionary_page_mixin.dart::_calcMixinPopupPosition` 因此始终使用偏好里的最大
  高度，内容较少时外壳也不会收缩。
- **[x] ① 已修复** — `popupRendered` 同时回传 WebView 视口高度，Dart 用
  `当前外壳高度 + 内容高度 - 视口高度` 得出包含 Flutter 顶栏的目标总高，并在用户
  最小/最大高度内自适应；底部固定模式和正在拖拽尺寸时保持原有固定尺寸语义。
- **[x] ② 已加自动化测试** — `dictionary_popup_layer_test.dart` 覆盖收缩、内容增长、
  最大高度与无效测量；`dictionary_popup_webview_test.dart` 覆盖离屏视口回退；
  `popup_font_ready_gate_test.js` 覆盖 JS 高度/视口/token 三元上报。macOS 真 app 浮层
  实测 DOM 内容 267、外壳从最大 360 自动收到 296。
- **备注**：仅对用户截图所在的 video/首页/texthooker mixin 弹窗启用；reader 家族本次
  不扩范围。
