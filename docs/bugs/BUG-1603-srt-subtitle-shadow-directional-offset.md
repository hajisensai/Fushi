## BUG-1603 · SRT 字幕柔和投影方向性偏下，真机上观感为阴影错位
- **报告**：2026-08-13（用户：iOS 上 SRT 字幕「阴影错位/方向不对」）
- **真实性**：✅ 真 bug，但**根因在参数不在渲染层**——这一点走了弯路才定下来，过程值得留档。
  - 先在 iOS 模拟器（iOS 18.6）复现失败：像素量化显示模糊半径 1→2→3→6 扩散量单调线性、偏移精确生效，**渲染完全按规格**。期间一张截图曾显示字形整个变黑，重跑 3 次（含同帧内画两遍、5 个字号并排）均未复现，判定为偶发帧，不是缺陷。
  - 真机（iPhone SE，iOS 26.6，**DPR=2**）取到像素后才定案。同一份 `■` 字形，四边暗度积分：

    | 配置 | 上 | 下 | 左 |
    |---|---|---|---|
    | **`offset(0,1)` blur3（生产）** | **1** | **218** | 41 |
    | `offset.zero` blur3 | 54 | 61 | 41 |
    | 无阴影 | 0 | 0 | 0 |

    零偏移那组上下 **54/61 基本对称**，证明高斯模糊渲染没有任何问题；而 1 逻辑像素的下偏把**上方光晕压到 1、下方放大 3.5 倍**。原因是 `defaultShadowThickness = 3` 的模糊很紧（真机上 sigma 只有几个物理像素），1 逻辑像素 = 2 物理像素相对于这个尺度不是"微调"而是"整体位移"，于是观感从「字后一团柔和黑影」退化成「阴影整个掉到字下面」。用户说的「方向不对」就是这个。
  - 根因位置：`fushi/lib/src/media/video/video_subtitle_style.dart` 的 `buildSubtitleSoftShadow`——`Shadow(..., offset: const Offset(0, 1))`。该 1px 下偏原是抄 Niratan `SubtitleOverlayView` 的 `.shadow(..., y: 1)`，但 Niratan 是 SwiftUI 的默认模糊口径，与 Flutter `blurRadius→sigma` 的换算不同，照搬偏移量并不等价。
- **[x] ① 已修复** — `buildSubtitleSoftShadow` 的 offset 改为 `Offset.zero`，投影环绕字形四周。不影响「尊重 .ass 自带样式」那条分支（`\bord`/`\shad` 走 `buildSubtitleStrokePaint` 与 ASS 硬投影，与本函数无关）。（提交：本提交）
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_style_test.dart` 新增 `BUG-1603 守卫：任意 thickness 下偏移都必须为零`（扫 0.5~12 共 8 个 thickness），并把原有两条断言的期望从 `Offset(0,1)` 改为 `Offset.zero`；`test/widgets/video_subtitle_overlay_test.dart` 与 `test/media/video/video_subtitle_overlay_markup_test.dart` 的 3 处 overlay 层断言同步跟进。
- **备注**：
  - **验证手段留档**（真机调试通道在本机不通时的可复用办法）：Xcode 26.6 装好后 `flutter drive` 仍卡在调试器附着，改走「探针编 **profile** 模式（AOT 可独立启动，debug 模式在 iOS 14+ 必须有调试器附着）→ app 自己 `RepaintBoundary.toImage()` 把 PNG 写进自身 Documents → `devicectl device install` + `process launch` 独立跑 → `devicectl device copy from --domain-type appDataContainer` 拉回主机」。全程不需要 driver 连接。
  - 踩坑：残留的 `--start-paused` devicectl 进程会卡住 app；多次安装会让设备端 LaunchServices GUID 错位（重装即修复）。
  - **教训**：模拟器（DPR=3、iOS 18.6）与真机（DPR=2、iOS 26.6）在"1 逻辑像素相对于模糊尺度有多大"上表现不同，纯视觉类问题不能只信模拟器；但也不能只信一张截图——本条中途就有一次凭单张截图误判"字形变黑"。
