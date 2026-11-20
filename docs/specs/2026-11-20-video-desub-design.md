# 内嵌字幕擦除（video desub）设计

- 日期：2026-11-20
- 拍板：所有者 2026-11-20「都做 全部上」；高动态档用 RAFT + LaMa 自研（不接 ProPainter）；分 4 个 PR。
- 设计图：本地 `fushi/build/desub_design/index.html`（不入库）。
- 参考：[YaoFANGUK/video-subtitle-remover](https://github.com/YaoFANGUK/video-subtitle-remover)（Apache-2.0）的流程「检测字幕区 → 时序掩膜 → 补全 → 重新封装」。

## 1. 目标

学日语看动画时，片源常带烧进画面的中文硬字幕。现有「字幕遮布」（`video_subtitle_mask.dart`）只能手动摆一块模糊 / 纯色块，且只是 Flutter 叠层——mpv 截图（制卡截图、片段导出）里硬字幕还在。本设计分三档：

| 档位 | 实时性 | 原理 | 平台 |
|---|---|---|---|
| 遮布（已有，改名「手动」） | 实时 | 用户摆放的固定矩形 | 五端 |
| 智能遮布（PR1） | 实时 | 播放中抽帧跑本机 OCR，自动找到字幕框，只在有字时糊掉，框跟着字走 | 有本机 OCR 模型的平台 |
| 彻底擦除（PR2～4） | 后台生成 | 检测 → 掩膜 → AI 补全 → 只重编有字片段，另存「无硬字幕版」 | Win / macOS / Linux 本机；手机委托互联电脑 |

## 2. 许可证结论（硬约束）

Fushi 是 GPL-3.0。可用：STTN（MIT）、LaMa（Apache-2.0）、RAFT（BSD-3）、PP-OCR（Apache-2.0）。
**不可用**：ProPainter（NTU S-Lab License 1.0，非商用）、E2FGVI（CC BY-NC 4.0）——代码与权重都带非商用限制，与 GPL「不得附加限制」冲突，不随包、不提供下载、不移植其代码。

## 3. PR1：智能遮布

### 3.1 行为

- 偏好 `video_subtitle_mask`（冻结键名）JSON 新增字段 `mode`：`manual`（缺省，兼容旧值）/ `smart`。
- `smart` 时 `rect` 的含义从「遮布位置」变成「搜索区域」：只在这块里找字，框外的字（招牌、片名、日文画面字）不动。编辑层与「调整位置」入口照旧，横幅提示文案随模式切换。
- 播放中按帧变化抽样（串行：上一帧识别完才截下一帧，最短间隔 `kSmartSubtitleMaskMinInterval`）；暂停且帧没变时不抽样。
- 迟滞：检测到字立刻显示；连续无字超过 `kSmartSubtitleMaskHoldEmpty` 才淡出——句间空档不闪。已知边界：长时间无字后的第一句，在首次识别完成前（约一个采样周期）会露出一下；要逐帧无痕得用「彻底擦除」。
- 遮布矩形 = 本帧所有横排行框的并集，四周按行高留边，再钳进搜索区域；换句时动画过渡到新框。
- 本机 OCR 模型不可用（没下载 / 平台不支持）时：遮布退回按搜索区域整块常显（等同手动档），并提示一次去设置里下载模型。

### 3.2 结构

- 截帧：`VideoPlayerController.captureRawFrameCrop(region)`——media_kit 补丁给 `screenshot` 加 `image/x-fushi-bgra` 格式 + `fushiRawTransform` 回调，在截帧 isolate 上拿到 `screenshot-raw video` 的 BGRA 缓冲后就地调用回调，**不做纯 Dart 的 PNG/JPEG 编码**（1080p 一次几百毫秒，持续采样不可接受）。只截视频本身，不合成字幕。
- 裁剪 + BGRA→RGBA 就是那个回调（`rawVideoFrameCropTransform`），只拷贝搜索区域的行，整帧不出截帧 isolate、不另起 isolate；识别走 `LocalScreenOcr.recognizeRgba`（PP 行检测 + 识别，会话常驻，与截屏识字 / 硬字幕 OCR 同一套本机模型）。
- 迟滞与框计算是纯函数 `SmartSubtitleMaskTracker`（`smart_subtitle_mask_tracker.dart`），单测覆盖；采样循环 `SmartSubtitleMaskSampler` 只负责「何时截、截完喂给 tracker」，输出一个 `ValueListenable<Rect?>` 给遮布层。
- 这里没有新的计算型子系统：识别复用现有 OCR，tracker 是几十行的几何。重活（彻底擦除）在 PR2 的 Rust crate。

## 4. PR2：擦除核心 `native/fushi_desub`（Rust 胖核心）

- Rust crate，C ABI + `dart:ffi`；推理用 `ort`（ONNX Runtime，GPU：Windows DirectML / CUDA、macOS CoreML、Linux CUDA，回落 CPU）。与 `native/fushi_upscale`（漫画超分，并行开发中）共用 ort 装配方式，谁先合入谁定基线。
- 粗粒度命令：`desub_job_start(config_json) -> job_id`、`desub_job_cancel`、`desub_job_pause/resume`；一条事件流（阶段、进度、预计剩余、错误码）。Dart 不存镜像状态。
- 管线：
  1. **检测**：PP-OCR 行检测（ONNX，与 app 同一份模型文件）抽样跑全片，得到每帧行框；只保留搜索区域内的框，按水印 / 字幕分类（位置常驻且跨大量镜头 = 水印）。
  2. **时序掩膜**：同一句跨帧合并成区间，掩膜膨胀若干像素盖住描边与阴影；输出「有字片段表」。
  3. **补全**：按算法：
     - `lama`（动画默认）：逐帧 LaMa，裁出掩膜周边的方块送进模型，贴回。
     - `sttn`（真人默认）：STTN 时序窗口，借前后帧的真实背景。
     - `flow`（高动态）：RAFT 光流把相邻帧未被遮挡的真实像素沿光流传播进掩膜，传播不到的残洞交给 LaMa。自研，不参考 ProPainter 代码。
  4. **封装**：调 ffmpeg，无字片段按 GOP 边界尽量流拷贝，有字片段重编码；音轨 / 字幕轨 / 章节原样拷贝。产物落在视频旁 `<名字>.desub.mkv`（或任务目录），原文件不动。
- 模型分发：走现有本机模型下载器（manifest + 指纹），按需下载，不随包。
- 片源自动推荐算法：首帧抽样做「平涂度」判断（色块数 / 边缘密度）→ 动画推荐 `lama`，否则 `sttn`；用户可改。

## 5. PR3：编辑页、任务、对比与切换

- 全屏编辑页（设计图②）：原画 / 掩膜 / 预览结果三视图，拖帧时间轴标出有字片段，多块区域，算法与设备选择，用时与空间预估，「先试 10 秒」。
- 任务并进现有任务面板（设计图③），一集一行、分阶段进度、整季批量。
- 同一视频记录登记「无硬字幕版」变体：进度 / 制卡 / 统计共用，切换是换源不是换条目；播放器顶栏「原片 / 无硬字幕 / 对比」，对比是可拖动分割滑块（设计图④）。
- 制卡截图与片段导出取当前在播的版本——擦除后的卡片截图不再带中文硬字幕。

## 6. PR4：手机委托电脑

- 复用「手机让电脑下」的执行设备层（`remote_download_execution`）：手机端选一台在线电脑，任务在电脑上跑，完成后回传或直接串流（设计图⑤）。
- 手机本机不跑补全模型。

## 7. 不做

- 不在播放时实时跑神经网络补全（现有模型都到不了实时，见调研）。
- 不接 ProPainter / E2FGVI（许可证）。
