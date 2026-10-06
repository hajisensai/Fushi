# Flutter 3.44.0 Windows 引擎补丁：合成器内 HDR 输出

让 HDR 视频画在 Flutter **自己的**交换链里（R16G16B16A16_FLOAT + scRGB），
不再需要把 libmpv 的 gpu-next 画进主窗后面的独立宿主窗。只改 Windows 嵌入层
（`flutter_windows.dll`），Dart 侧与其它平台不受影响。

## 基线

| 仓库 | 提交 |
|---|---|
| flutter/flutter（tag 3.44.0） | `559ffa3f75e7402d65a8def9c28389a9b2e6fe42` |
| 引擎版本（`bin/internal/engine.version`） | `4c525dac5ebe5971c5708ef73558ed8edcf4a362` |
| ANGLE（`engine/src/flutter/third_party/angle`，DEPS 拉取） | `84027aca9b71c9ba335bd000dad1107b8810a511` |

升级 Flutter 时两份补丁都要重新对齐基线；`tool/engine_overlay.ps1` 会拒绝把
引擎版本不符的产物装进 SDK。

## 两份补丁

### `engine-hdr-output.patch`（flutter 仓库根目录 `git apply`）

- 新导出 `FlutterDesktopViewSetHdrOutput(view, enabled, sdr_white_nits)`：按 view 开关。
- `egl::Manager`：可选的 RGBA16F 配置（`EGL_EXT_pixel_format_float`）+ 不绑配置的
  上下文（`EGL_KHR_no_config_context`），同一上下文能挂 8-bit 与半浮点 surface；
  HDR 窗口 surface 带 `EGL_GL_COLORSPACE = EGL_GL_COLORSPACE_SCRGB_LINEAR_EXT`。
  任一扩展缺失 → HDR 不可用，原版路径不受影响。
- 合成器：HDR 开启时 backing store 是 RGBA16F，存「扩展范围 sRGB」（1.0 = 界面白，
  视频高光 >1、广色域为负分量）；Present 用一个 shader pass 解码成 scRGB
  （去预乘 → 保号 sRGB EOTF → × SDR 白/80 → 预乘）写进交换链。该 pass 保存并恢复
  它碰过的全部 GL 状态（与 Skia 共用上下文，泄漏 `GL_ARRAY_BUFFER` 会让 Skia
  下一帧把 VBO 偏移当指针读，ANGLE 内访问违例）。
- 外部纹理：`kFlutterDesktopPixelFormatRGBA16F`（=3）的 GPU surface 描述符按半浮点
  导入，Skia 侧按 `kRGBA_F16` 采样，不钳位。
- 渲染目标缓存按尺寸命中，补了「格式代」计数：开关 HDR 时作废旧 backing store。
- 诊断：`FUSHI_HDR_PROBE=1` 时在切到 RGBA16F 后第 120 帧回读 backing store 三个点；
  状态切换以 `FML_LOG(IMPORTANT)` 记一行（只在变化时）。
- Impeller 路径不支持（`SetHdrOutput` 直接返回 false）。

### `angle-scrgb-swapchain.patch`（ANGLE 仓库根目录 `git apply`）

ANGLE 的 D3D11 后端原本**从不设置交换链色彩空间**，也不声明
`EGL_EXT_gl_colorspace_scrgb_linear`。没有色彩空间标记的 FP16 交换链被 DWM 当
sRGB 合成，>1.0 全被钳掉（实测：backing store 里 2.57，桌面上 1.000）。补丁：

- Win32 构建声明 `EGL_EXT_gl_colorspace_scrgb_linear`；
- 窗口 surface 请求 scRGB-linear 时改建 **flip 模型**交换链（DWM 只在 flip 模型上
  认色彩空间），`CheckColorSpaceSupport` 确认可呈现后 `SetColorSpace1(G10_P709)`；
  任何一步不行就让 surface 创建失败（引擎随之回退 8-bit），不做静默降级。

## 构建与产物

本地实测流程（Windows，VS 2022 + Windows SDK 10.0.26100）：

1. 用 depot_tools 同步 3.44.0 的引擎源码（`gclient sync`），打上两份补丁。
2. `flutter/tools/gn --runtime-mode {debug,profile,release} --no-rbe` 后
   `ninja -C out/host_<mode> flutter/shell/platform/windows:flutter_windows`。
3. 产物（`flutter_windows.dll` / `.dll.lib` / `.dll.exp` / `.dll.pdb`，以及
   `flutter_windows.h` / `flutter_texture_registrar.h`）按
   `windows-x64` / `windows-x64-profile` / `windows-x64-release` 布局放好，附
   `engine-overlay.json`（`engineVersion` + `patchVersion`）。
4. `tool/engine_overlay.ps1 -ArtifactDir <产物> [-FlutterRoot <SDK>]` 装进 SDK 缓存
   （原文件备份到 `.stock-backup`，`-Restore` 还原）。

## 运行时契约

- runner 用 `GetProcAddress` 解析 `FlutterDesktopViewSetHdrOutput`：原版引擎没有这个
  导出 → 报告不支持，app 继续走宿主窗路径。补丁引擎与原版引擎都能跑同一份 app。
- media_kit 只在引擎报告支持之后才交出 format=3 的纹理描述符。
