## BUG-5268 · windows-display-off-black-screen
- **报告**：2026-11-22（应用内反馈 22qnhluO50，开发者本人）
- **真实性**：✅ 现象属实（关显示器再开后 Fushi 画面不出）；具体失效层未定。现有处理 `fushi/windows/runner/flutter_window.cpp:5117-5128` `OnDisplayRecovered` 只 `ForceRedraw()`（TODO-689），按引擎源码只能补一帧，不碰表面。
- **[ ] ① 未修复** — 2026-11-23 对 3.50.0 + 补丁引擎源码（`D:/fe350/flutter/engine/src/flutter`）的核对结论：
  - 显示器断电本身不会弄坏交换链：ANGLE `SwapChain11.cpp:930-944` 只有 `DXGI_ERROR_DEVICE_REMOVED/RESET` 才返回 `EGL_CONTEXT_LOST`，其他 Present 失败照常返回成功，这类情况 `ForceRedraw` 已够。
  - 所以 ForceRedraw 之后仍黑只剩两种成因：(a) D3D 设备丢失——ANGLE 上下文丢失后不复位，Flutter `egl::Manager` / Impeller GLES 上下文只建一次，引擎无重建路径；(b) 表面永久失效——`flutter_windows_view.cc` `ResizeRenderSurface` 与补丁里的 `EnsureSurfaceFormat` 都是先销毁旧表面再建新的，新建失败就留下 `is_valid_=false` 的表面，此后每帧失败，`OnWindowSizeChanged` 在表面无效时只发窗口尺寸，全引擎没有重建表面的地方。
  - runner 层没有公开接口能救回 (a)(b)，定时 resize 抖动对两者都无效。
  - **下一步**：① 取证——引擎 `FML_LOG`（"EGL Error" / "Present failed" / "View resize failed to create surface"）只写 stderr，发布包里 `utils.cpp:13-17` 只在有控制台时接 stderr，日志全丢；需先把 stderr 落进应用日志，真机复现一次分清 (a)(b)。② 根修走引擎补丁（`ci/patches/flutter-engine/3.50.0/README.md` 流程）：(b) 加导出 `FlutterDesktopViewRecreateSurface` 或让 `OnWindowSizeChanged` / `EnsureSurfaceFormat` 在表面无效时按客户区重建，并改成「先建新的、成功再换旧的」；(a) 需要引擎支持 GPU 上下文重建，工作量大。
- **[ ] ② 未加自动化测试** —
- **备注**：开发者机 11-22 当晚系统日志无 nvlddmkm / TDR 事件；Fushi 23:17:44 有一次 5.1 秒主线程卡顿，hang dump `%LOCALAPPDATA%/Fushi/crashdumps/hang-83328-374044359.dmp`，与黑屏是否相关未确认。
