## BUG-4008 · Linux 查词弹窗词典内容不显示但可点击、可制卡
- **报告**：2026-11-04（反馈 #63DhJLTAHW，Arch Linux，3.0.1+19816，1440x928@1.0：「词典查词时无法正常显示，词典内容可正常点击，可正常导出卡片」；3 张截图未随导出）。
- **真实性**：❌ 未复现。「能点、能制卡、看不见」说明 DOM 与 JS 桥都在工作，问题在 Linux WPE WebView 的出图层（`packages/flutter_inappwebview_linux`），而本机只有 Windows，无法跑 Linux WPE。日志里与 WebView 有关的只有一条 `DictStylePreview` 的空断言，那是离开词典样式页的生命周期问题（已单独记为 BUG-4005 并修复），与查词弹窗不出图无关；其余是 `libfushi_torrent_ffi.so` 缺失与下载失败，同样无关。v3.0.1 之后 `packages/flutter_inappwebview_linux` 只有依赖升级与词典脚本沙箱（34eaa2e44d）改动，没有出图相关修复，不能说 develop 已修。
- **[ ] ①** —
- **[ ] ②** —
- **备注**：Linux 为社区维护平台。需要在 Linux 上用当前 develop 复测，并确认 GPU / 合成器环境（Wayland/X11、`WEBKIT_DISABLE_COMPOSITING_MODE`）与 `transparentBackground`（`linux/in_app_webview/in_app_webview_settings.cc:329`）是否相关后再定位。
