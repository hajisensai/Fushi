# 视频 HDR 直通（Windows）实现计划

- 日期：2026-08-30
- 基线：`origin/develop@7d76382446`
- 状态：**Phase 0 探针原型待跑 → 用户拍板架构 → Phase 1 实现**
- 前置：PR #1066（HDR 色调映射旋钮，OPEN）只做了 HDR→SDR 映射的用户控制，明确写明「直通没做」。本计划就是那条没做的直通。

---

## 0. 需求理解

用户原话：「实现 hdr」（承接 #1066 表格里「直通做不到，卡在 vendored media_kit 的 8-bit `DXGI_FORMAT_B8G8R8A8_UNORM`」那一行）。

我的理解：**HDR 片源在 Windows HDR 显示器上按 HDR 输出**（PQ/HLG 元数据、10-bit、峰值亮度交给显示器），
而不是现在这样在 mpv 内部被色调映射成 SDR 再交给 Flutter 的 8-bit 合成器。判据只有一条：Windows HDR 模式开着、放一个 HDR10 片，
显示器收到的是 HDR 信号（DXGI 交换链 colorspace = `RGB_FULL_G2084_NONE_P2020` 或 scRGB FP16），高光亮度超过 SDR 白。

### Linus 三问

1. **真问题还是臆想？** 真问题。本机就是 10-bit / 1015 nit 峰值 / 广色域面板（§1.4 实测），HDR 片源在动画/番剧种子里很常见（`anime_release_descriptor.dart` 专门解析 `HDR10+` 标签）。现在的体验是「HDR 片全部被砍成 SDR」。
2. **有更简单的方法吗？** 没有。§1 证明 Flutter 合成路径的三层格式都是 8-bit SDR，任何「在纹理路径上改格式」都到不了显示器（§2 方案 C 的分析）。唯一的路是让视频**绕开 Flutter 合成器**。
3. **会破坏什么？** 视频画面上叠着 16 层 Flutter 控件 + 根 Overlay 的查词弹窗（§1.3）——这是本 app 的核心价值（逐字查词、制卡），**任何让这些层看不见的方案都不可接受**。这条约束直接淘汰了「原生子窗口盖在 Flutter 上」的最简做法（§2 方案 B）。

---

## 1. 现状事实（已核实，含 file:line）

### 1.1 当前 Windows 渲染链路：三层都是 8-bit SDR

| 层 | 事实 | 位置 |
|---|---|---|
| mpv 输出 | `vo=libmpv` render API（app 从不设 `vo`，fork 默认 `'libmpv'`），渲染进 ANGLE FBO | `third_party/media_kit_video/lib/src/video_controller/native_video_controller/real.dart:119-121`；`fushi/lib/src/media/video/video_player_controller.dart:1312-1316` 只传 `hwdec` |
| 共享纹理 | `DXGI_FORMAT_B8G8R8A8_UNORM`，双纹理 `CopyResource` 交接 | `third_party/media_kit_video/windows/angle_surface_manager.cc:261` |
| Flutter 纹理 API | 只认 `kFlutterDesktopPixelFormatRGBA8888 / BGRA8888` | `flutter_texture_registrar.h:46-53`（引擎预编译产物，不可改） |
| Flutter 交换链 | 引擎自建 ANGLE 8-bit 交换链，无 HDR/色彩空间 API | `flutter_windows.h` 全文无 composition/alpha/colorspace 相关符号 |

结论：即使把 `:261` 改成 `R10G10B10A2` / `R16G16B16A16_FLOAT`，Flutter 采样进自己的 8-bit 交换链时就砍回 SDR，DWM 收到的仍是 sRGB 窗口。**HDR 信号在纹理路径上无处可出**。

### 1.2 mpv 侧能力：齐全

vendored `libmpv-2.dll`（`mpv v0.41.0-856-g33111f321`，`fushi/build/windows/x64/runner/Release/`）字符串扫描命中：
`d3d11-output-csp`、`d3d11-output-format`、`target-colorspace-hint`(×3)、`target-peak`、`gpu-context`、`gpu-next`、`rgb10_a2`、`rgba16f`。
mpv 手册（master）：`--target-colorspace-hint=auto` 在 D3D11 上通过设置交换链元数据实现 HDR 直通；`vo=gpu-next` 默认 `--target-colorspace-hint-strict`。
所以 **mpv 只要拿到一个自己的 HWND（`--wid`）+ `vo=gpu-next --gpu-context=d3d11`，HDR 直通是现成的**；`hwdec=d3d11va` 在这条路上照常零拷贝。

### 1.3 视频画面之上的 Flutter 层（必须全部保留）

`fushi/lib/src/pages/implementations/video_fushi/layout.part.dart:329-541` 的 controls Stack，从底到顶 16 层：
`AdaptiveVideoControls` → 章节刻度 → 悬停缩略图 → `VideoDanmakuOverlay` → **`VideoSubtitleOverlay`（逐字可点查词，`:401-506`）** → OSD → 长按倍速 → 自动连播 → 黑屏闪烁提示 → 字幕拖拽横幅 → 音量/亮度 HUD → 侧边动作栏 → 侧面板抽屉（`side_panel.part.dart:128`）→ 控件 popover → 布局编辑 → 光标层。
另有 push-aside 的字幕跳转面板（`:835-887`）和**根 `Overlay` 里的查词弹窗**（`video_fushi_page.dart:4389-4487`，要浮在全屏路由之上）。
media_kit 自带 `SubtitleView` 已禁用（`:98-100`），libmpv 平时 `sub-visibility=no`（`video_player_controller.dart:1430-1433`），只有 PGS 位图字幕例外走画面渲染（`:855-856`）。

### 1.4 本机探针（2026-08-30 实测，`$CLAUDE_JOB_DIR/tmp/hdrprobe.cpp`，DXGI `IDXGIOutput6::GetDesc1`）

```
adapter 0: NVIDIA GeForce RTX 5090
  output 0: \\.\DISPLAY1 bits=10 colorspace=0 (SDR sRGB) maxLum=1015 maxFALL=750 minLum=0.0505
            primR=(0.677,0.312) primG=(0.270,0.682)
```
→ 面板是 HDR 面板，**Windows HDR 模式当前关着**。真机验证前要 Win+Alt+B 打开；也说明「自动模式」必须以 DXGI 输出 colorspace 为判据，不能只看面板能力。

### 1.5 runner 里已有的原生窗口先例——**没有一个是「Flutter 内容透明盖在别的东西上」**

| 窗口 | 透明手段 | 位置 |
|---|---|---|
| 浮动歌词 / hook 工具条 / 查词阴影 | D2D→DIB→`UpdateLayeredWindow(ULW_ALPHA)`，纯 GDI 推像素，**没有 Flutter** | `floating_lyric_window.cpp:420-422,2102`；`hook_toolbar_window.cpp:566,928`；`global_lookup_shadow.cpp:112-119,346` |
| 剪贴板查词面板（WebView2） | 唯一的 DComp + `WS_EX_NOREDIRECTIONBITMAP` 尝试，**实机透明像素合成成黑**，已在 `flutter_window.cpp:1686-1693` 关掉，退回整窗 `LWA_ALPHA` | `global_lookup_window.cpp:1963-2037,2398-2439` |
| 主窗 | `WS_OVERLAPPEDWINDOW`，`ex_style=0`，不透明画刷；Flutter view 是唯一子 HWND（`SetParent`）；无 `DwmExtendFrameIntoClientArea` | `win32_window.cpp:150,210-219,368-376`；`flutter_window.cpp:557` |

仓里只有一个 Flutter 引擎（`flutter_window.cpp:373` / `main.cpp:241`）。**「Flutter 交换链的 alpha 能否到达 DWM」在本仓从未被验证过**——这是整个计划唯一的硬性未知，Phase 0 只为回答它。
runner 已链接 `dcomp dwmapi d3d11 dxgi`（`fushi/windows/runner/CMakeLists.txt:57,80,87`），原型不需要新依赖。

### 1.6 相关在途工作

- PR #1047（BUG-1933，OPEN 未合）：runner 自有「保边框巨窗 + `HWND_TOPMOST`」全屏。HDR 宿主窗的 z-order 同步必须与它兼容（§4.3）。
- PR #1066（OPEN）：`tone-mapping` / `hdr-compute-peak` 旋钮。直通模式下这两项继续有意义（显示器峰值不够时 mpv 仍要映射），无冲突。

---

## 2. 核心判断

**✅ 值得做，但只有一条路，且这条路的可行性要先用原型证明。**

| 方案 | 做法 | 结论 |
|---|---|---|
| A（推荐，待 Phase 0 证实） | **双窗口**：mpv 拿一个独立顶层宿主 HWND（`WS_POPUP`、`WS_EX_NOACTIVATE\|TOOLWINDOW`），`vo=gpu-next --gpu-context=d3d11 --wid=<hwnd> --target-colorspace-hint=auto`，自建 HDR 交换链；宿主窗 z-order 钉在主窗**正后方**；主窗的视频矩形画成透明（alpha=0），Flutter 16 层控件照常画在上面，DWM 负责把 SDR 的 Flutter 层合成到 HDR 画面上 | 唯一既保留全部 Flutter 层、又不改 Flutter 引擎的路。**前提**：Flutter 子窗交换链的 alpha 能被 DWM 采纳（`DwmExtendFrameIntoClientArea(-1)` 是 DX 应用做透明窗的标准招；剪贴板面板的黑色失败是 WebView2 composition controller 的问题，不能直接推到 Flutter 上，但也不能反证） |
| B | 原生子窗口盖在 Flutter 上，字幕/OSC 全交给 mpv 自己画 | 16 层 Flutter 控件 + 查词弹窗全部被遮。**违反 §0 铁律，否决** |
| C | 纹理路径升 10-bit/FP16 | 到不了显示器（§1.1）；还会把 mpv 的抖动换成 Skia 的截断，**倒退**。否决 |
| D | fork Flutter Windows 引擎加 HDR 交换链 | 引擎是预编译产物，本仓没有引擎构建链；量级和维护成本不成比例。否决 |
| E | LWA_COLORKEY 色键透明（1-bit alpha） | 半透明控件（控制条渐变、字幕底色）会和色键色混出错色。只作 A 的降级备胎，不作主方案 |

**关键洞察**
- 数据结构：新增一个「视频宿主矩形」——Flutter 侧 `Video` 的全局矩形 → 原生宿主窗位置/尺寸。这是唯一新增的跨边界状态，**单向流**（Dart 布局 → 原生窗），原生永不反向改布局。
- 复杂度：模式切换只有两态 `texture | hostWindow`，由**一个**派生判据决定（§4.4），不在各处补 if。
- 风险点：z-order（激活/最小化/多显示器/DPI/全屏）同步；每一处都是 Win32 的老坑，Phase 1 必须靠集成测试逐项咬住。

---

## 3. Phase 0：探针原型（0.5 天，不合入，只出结论）

目的：回答「主窗内的 Flutter 内容能不能以逐像素 alpha 合成到主窗后面的另一个顶层窗口上」。

步骤（全部在本 worktree，debug/环境变量门控，不进 develop）：
1. runner：环境变量 `FUSHI_HDR_SPIKE=1` 时，在主窗创建后 (a) 建一个 `WS_POPUP | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` 顶层窗，D3D11 flip 交换链清成纯绿色（`#00FF00`），矩形 = 主窗客户区屏幕坐标，`SetWindowPos(spike, hwndMain, …)` 插到主窗正后方，主窗 `WM_WINDOWPOSCHANGED/WM_SIZE/WM_MOVE` 时跟随；(b) 主窗 `DwmExtendFrameIntoClientArea(&{-1,-1,-1,-1})`。
2. Dart：`bool.fromEnvironment('FUSHI_HDR_SPIKE')` 时，视频页把 `Video` 换成透明占位（`SizedBox.expand()`）并把页面 `Scaffold`/`fill` 背景改 `Colors.transparent`；其余 16 层不动。
3. 用确定性开页钩子（`docs/agent/computer-use-testing.md`）离屏开一个视频，截屏。
4. 判据：
   - ✅ 视频区看到**绿色** + 控制条/字幕层清晰叠在绿色之上 → 方案 A 成立，进 Phase 1。
   - ❌ 视频区黑/主题色（alpha 被丢）→ 再试两种变体：(i) 主窗+Flutter 子窗都加 `WS_EX_LAYERED` + `LWA_ALPHA 255`；(ii) 方案 E 色键。两者都失败 → 方案 A 判死，回到用户处拍板是否接受方案 B 的「HDR 纯观影模式」（无查词）或搁置。
5. 变体 (ii) 若成功但 (i)/主路径失败，则只能提供「HDR 模式下控件不透明」的降级体验，需用户拍板。

---

## 4. Phase 1：实现（方案 A 成立后，3–5 天）

### 4.1 runner：`HdrVideoHostWindow`（新文件 `fushi/windows/runner/hdr_video_host_window.{h,cpp}`）
- 建窗/销毁；`SetHostRect(screen px)`；`SyncZOrder()`（插在主窗正后方，`SWP_NOACTIVATE`）；跟随主窗 `WM_WINDOWPOSCHANGED`（含最小化/还原/显示器切换/DPI）；主窗 `WM_ACTIVATE` 后重钉 z-order（TOPMOST 全屏时主窗是 TOPMOST，宿主窗插在其后自然也在 TOPMOST 带内）。
- 通过既有 `app.fushi/window` 类 MethodChannel 暴露：`hdrHost.create → hwnd`、`hdrHost.setRect`、`hdrHost.destroy`、`hdrHost.displayColorSpace`（DXGI `GetDesc1().ColorSpace`，供 §4.4 判据；`WM_DISPLAYCHANGE` 时向 Dart 推事件）。
- 主窗透明：仅在宿主窗存活期间 `DwmExtendFrameIntoClientArea(-1)`，销毁时还原（§3 若证明需要 `WS_EX_LAYERED` 则同样成对开关）。

### 4.2 media_kit_video fork：`VideoOutput` 新增 `hostWindow` 模式
- `VideoOutputManager.Create` 增参 `wid`（可空）。有 `wid` 时 `VideoOutput` **不建** `ANGLESurfaceManager`、不注册 Flutter 纹理，改为向 libmpv 设：`vo=gpu-next`、`gpu-context=d3d11`、`wid=<hwnd>`、`target-colorspace-hint=auto`、`d3d11-output-csp=auto`；`hwdec` 沿用 `resolvePlatformHwdec`。
- Dart `NativeVideoController` 新配置字段 `hostWindowHandle`；`Video` 小部件在此模式下渲染透明占位，并用 `RenderBox.localToGlobal` + 窗口原点把矩形喂给 `hdrHost.setRect`（`fit`/黑边逻辑改为在占位内算目标矩形，mpv 侧 `video-unscaled`/`keepaspect` 关掉，由 Dart 决定矩形——保持「谁布局谁说了算」）。
- 缩略图/截图：`player.screenshot()` 走 `screenshot-raw`，`vo=gpu-next` 支持；`_buildThumbnailPreviewOverlay` 本来走 ffmpeg，不受影响。`glsl-shaders`（超分）在 gpu-next 上照常。

### 4.3 与 PR #1047 的耦合
巨窗全屏靠主窗 `HWND_TOPMOST`；宿主窗每次 `SyncZOrder` 都以 `hwndMain` 为 insertAfter，天然跟随。需要在 #1047 合入后加一条集成用例：全屏进/出各一次，宿主窗矩形 = 主窗客户区且 z-order 紧随其后。若本计划先于 #1047 落地，全屏用例先咬 window_manager 路径。

### 4.4 模式判据（唯一派生 getter，不做逐路径 if）
`useHostWindow = Platform.isWindows && setting != off && displayColorSpace == HDR10 && sourceIsHdr`
- `setting`：新增 `video_hdr_output` = `auto | off`（默认 `auto`），进 `settings_schema_video.dart` HDR 分区（与 #1066 同区）；新设置项**必须**跑 `settings_schema_coverage_test` 决定是否登记 `kCoveredElsewhere`。
- `sourceIsHdr`：mpv `video-params/primaries == bt.2020 && gamma in {pq, hlg}`；在 `file-loaded` 后一次性读取。
- 任一输入变化（用户切 Windows HDR、换片）→ 重建 `VideoController`（两种模式的 mpv 上下文不能热切，重建代价 = 重开一次播放，保留进度）。
- 非 HDR 情况一律走现有纹理路径：**零行为变化，never break userspace**。

### 4.5 测试
- 守卫：`fushi/test/build/hdr_host_window_guard_test.dart`——`DwmExtendFrameIntoClientArea` 必成对；`SyncZOrder` 的 insertAfter 必是主窗；`useHostWindow` 只有一处定义。每条守卫**先变异实测**（改坏源码看它红）。
- Dart 单测：判据表（4 输入 × 真值）、矩形换算（fit contain/cover/fill 三态）、模式切换重建一次且只一次。
- 集成（Windows 离屏，`fushi/tool/run_windows_itest.ps1`，焦点驱动）：开 HDR 片 → 宿主窗存在且矩形吻合 → 最小化/还原/移动 → 矩形与 z-order复核 → 关片宿主窗销毁、`DwmExtendFrameIntoClientArea` 还原。

### 4.6 i18n
`fushi/tool/i18n_sync.dart --add` 加 `video_hdr_output_*` 若干 key（15 语言欠账按既有流程补译），`dart run slang` 后只用 `dart format --language-version=3.6` 生成文件。

---

## 5. Phase 2：真机验证与宣称门（1–2 天）

只有下列证据齐全才允许在 UI/文档里写「支持 HDR」：
1. Windows HDR 打开（DXGI colorspace 探针 = `RGB_FULL_G2084_NONE_P2020`），HDR10 样片（bt.2020 + PQ）播放中 mpv 日志出现 gpu-next/d3d11 交换链协商为 PQ/RGB10A2 或 scRGB FP16 的行（`--msg-level=vo=v`）。
2. 屏幕采样：`IDXGIOutput6::DuplicateOutput1` 以 `DXGI_FORMAT_R16G16B16A16_FLOAT` 抓帧，视频高光像素线性值 > 1.0（超过 SDR 白）；同一帧上叠加的 Flutter 字幕白字 ≈ SDR 白（DWM 按系统 SDR 白电平映射）。
3. 关 Windows HDR → 自动回到纹理路径，画面与现在逐像素一致（回归）。
4. 上述证据落 `.codex-test/hdr-passthrough/`（不入库），PR 里贴数字。

---

## 6. 明确不做（本计划范围外）

- **Android**：media_kit 走 `SurfaceTexture` → GL 8-bit；真 HDR 要 `SurfaceView` + HDR 格式 + MediaCodec 元数据透传，等于另一套 platform view 架构，且 BUG-465 的 Mali 16-bit OOM 还在。单独立项。
- **iOS/macOS**：Flutter 只有 wide-gamut 无 HDR 合成；macOS 走 media_kit 的 `CVPixelBuffer` 纹理，同样卡在 Flutter 合成器。单独立项。
- **Linux**：`vo=libmpv` + GL 纹理，Wayland HDR 协议本身尚在演进。不做。
- 不改 #1066 的两项旋钮语义。

---

## 7. 破坏性分析

| 可能受影响 | 应对 |
|---|---|
| 非 HDR 用户 | 判据不满足 → 纹理路径原样，零改动 |
| 主窗透明化影响其他页面 | `DwmExtendFrameIntoClientArea` 只在宿主窗存活期开启；非视频页面永不进入 |
| 外部工具截屏（Computer Use 巡检、`window_capture.cpp` WGC）| WGC 抓主窗只会抓到透明洞；巡检用例在 HDR 模式下需改抓显示器。记录在 `docs/agent/computer-use-testing.md` |
| 全屏（window_manager 路径 / #1047 巨窗）| §4.3 |
| 视频挖矿截图（Anki 卡图）| `screenshot-raw` 在 gpu-next 可用；截出来的是 HDR 原始帧，制卡时需 `screenshot-sw=yes` 让 mpv 先映射成 SDR 再交给卡片——Phase 1 列入用例 |
| 多显示器 / 混合 HDR-SDR 显示器 | 判据用**主窗所在显示器**的 colorspace；跨显示器拖动触发重判 |

---

## 8. 时间线与决策点

| 阶段 | 产出 | 决策 |
|---|---|---|
| Phase 0（0.5 天） | 绿窗原型截图 + 结论 | ✅ → Phase 1；❌ → 用户拍板：接受方案 B「HDR 纯观影模式」/ 搁置 |
| Phase 1（3–5 天） | runner + fork + Dart + 测试，一条 PR | 代码审查 |
| Phase 2（1–2 天） | 真机证据 | 宣称门 |
