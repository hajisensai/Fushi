## BUG-1976 · Windows 查词 WebView 被超分通路无条件重采样导致字体发糊
- **报告**：2026-08-30（用户：更新 Windows debug 12704 → 12751 后查词字体明显发糊）
- **真实性**：✅ 真 bug。两个安装包资产时间之间唯一修改共享 Windows WebView2
  栅格链的提交是 `5d3feac4cd`；它在
  `packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge_gpu.cc`
  的 `ProcessFrame` 中把 `src/dst` 任意异尺寸都送进 libplacebo。150% DPI 下 Flutter
  texture callback 与 method-channel 布局换算可能相差 1 个物理像素，普通查词 WebView
  因而也被整面重采样，文字从旧版 1:1 `CopyResource` 退化为过滤缩放。
- **[x] ① 已修复** — `587a44e74d`：普通 WebView 的 GPU bridge 以 WGC 捕获
  纹理尺寸分配目标并 1:1 `CopyResource`；只有显式启用 shader 时才使用
  `output_size_` 与 libplacebo 重采样。
- **[x] ② 已加自动化测试** —
  `fushi/test/media/video/web_video_shaders_test.dart` 静态守卫锁定 shader 门控、
  禁止重新以 `src/dst` 尺寸差自动启用 libplacebo，并要求普通 WebView 保留 1:1 直拷。
- **备注**：修复只收紧 shader 门控；用户选择的词典字体、网页视频启用超分时的
  半分辨率 capture → device-DPR output 路径均不改变。按用户要求不等待完整构建/设备验收。
