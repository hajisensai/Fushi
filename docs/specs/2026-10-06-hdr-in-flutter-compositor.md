# Windows：HDR 视频画进 Flutter 自己的交换链（合成器内 HDR）

日期：2026-10-06　分支：`feat/hdr-in-flutter-compositor`

## 为什么

旧方案（2026-08-30 直通计划）让 libmpv 的 `vo=gpu-next` 画进一个**钉在主窗正后方的独立
顶层窗口**，主窗用 DWM blur-behind 空区域挖洞透出它。用户感受是「视频和界面不在一个层级
上」，实际也确实是两个窗口：全屏切换 / 移动 / 层级变化时两者会短暂错位（BUG-2964 的顶部
横线、全屏时 Fushi 界面短暂消失都出在这套双窗口合成上）。

Flutter 的 Windows 嵌入层只会输出 8-bit sRGB，插件层面拿不到 HDR 交换链，所以根治只能改
引擎：让 Flutter 自己的交换链变成 FP16 scRGB，视频作为普通纹理和 UI 一起合成。

## 数据流

```
libmpv (vo=libmpv, gl_video)
  target-trc=linear, target-prim=bt.2020, target-peak=<面板峰值 | 203>
  → RGBA16F 线性 FBO（1.0 = 203 nit 参考白）
media_kit 编码 pass
  BT.2020→BT.709 矩阵（不裁剪，广色域成负分量）× 203/参考白 → 保号 sRGB OETF
  → R16G16B16A16_FLOAT 共享纹理（format=3）
Flutter 引擎（补丁）
  外部纹理按 kRGBA_F16 采样 → RGBA16F backing store（扩展范围 sRGB，1.0 = 界面白）
  Present：去预乘 → 保号 sRGB EOTF → × 界面白/80 → 预乘
  → FP16 交换链，色彩空间 G10_P709（scRGB），flip 模型（ANGLE 补丁）
DWM：scRGB 1.0 = 80 nit
```

亮度换算只有一处：`compositorHdrTarget()`（`video_hdr_output.dart`）。HDR 显示器：界面白 =
Windows「SDR 内容亮度」，HDR 片源按绝对亮度出，面板峰值以上才色调映射；SDR 显示器（「总是」
模式）：参考白对齐界面白、峰值 203，等同 mpv 自己输出到 SDR 屏。

## 实测（SDR 桌面 + FP16 桌面复制，`hdrcap`）

| 片源 | 期望 | 桌面 scRGB |
|---|---|---|
| hdrsplit 右半（PQ 92.2 nit），HDR 输出、白=80、峰值 1015 | 92 nit | 1.146（92 nit） |
| hdrsplit 左半（PQ 983 nit），同上 | ≤峰值，经色调映射 | 8.9（714 nit） |
| SDR 屏「总是」模式（参考白 203、峰值 203） | = mpv 线性值 | 0.879 / 0.353，与 mpv 输出逐位一致 |
| hdrtb（上亮下暗） | 上亮 | 上 0.879、下 0.353（方向正确） |
| `off` + SDR 片 | 原版 8-bit blit | 与截图同色 |

踩过的坑（都已修、都有守卫）：

1. 输出 pass 与 Skia 共用 GL 上下文，泄漏 `GL_ARRAY_BUFFER=0` 让 Skia 下一帧把 VBO 偏移当
   指针读，ANGLE `CopyNativeVertexData` 访问违例 → `ScopedOutputPassState` 全量保存恢复。
2. FP16 交换链不标色彩空间时 DWM 按 sRGB 合成、>1 全钳成 1.0（backing store 2.57，桌面
   1.000）；ANGLE D3D11 从不设色彩空间 → ANGLE 补丁。
3. 纹理格式与 mpv 目标分两次从 Dart 下发，中间夹一帧错编码 → 收进 media_kit 原生同一渲染
   线程任务。
4. 以为纹理 FBO 与 pbuffer 方向相反而加了 `FLIP_Y`，实测上下颠倒 → 去掉。

## 回退与边界

- 原版引擎（没有 `FlutterDesktopViewSetHdrOutput` 导出）、Impeller、ANGLE 缺扩展、软件渲染：
  一律报告不支持，走原来的宿主窗直通（行为不变）。
- **Dolby Vision Profile 5** 仍走宿主窗：Windows 随包 libmpv 的 gl_video 没有 DV 重整补丁
  （`textureRendererReshapesDolbyVision` 在 Windows 为 false），只有 gpu-next 能出正确颜色。
  宿主窗因此还不能删；要彻底去掉它，需要给 Windows libmpv 也打上 `mpv-gl-dovi-p5.patch`
  （macOS / iOS / Android 已有）。
- 未在真实 HDR 显示模式下验证（本机桌面是 SDR，按约定不替用户切显示器 HDR）。HDR 模式下
  的数值链与 SDR 模式只差 `compositorHdrTarget` 的分支，单测覆盖；首次在 HDR 显示器上用时
  请留意界面白与视频参考白的相对亮度。

## 产物与发布

见 `ci/patches/flutter-engine/3.47.6/README.md` 与 `docs/agent/build.md`「依赖补丁」。
