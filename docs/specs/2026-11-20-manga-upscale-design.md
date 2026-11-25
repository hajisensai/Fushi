# 漫画阅读器画质增强 / 超分设计（2026-11-20）

所有者已拍板的方向：给漫画阅读器做「超分 / 画质增强」，**第一评价指标是小字 / 假名的可读性**
（看漫画是为了看清字、查词），其次才是线条观感。分三档，本轮做 ① ③，② 往后放。

| 档 | 内容 | 状态 |
|---|---|---|
| ① 默认档（零开销） | 更好的缩放算法 + 文字感知 Gamma 校正，所有平台、默认开 | PR1 + PR-④ 实现 |
| ② 轻量实时档 | （往后放，不做） | — |
| ③ 低清页 AI 超分（离线） | 神经网络超分 + OCR 框融合，逐页处理、向后预取、落盘缓存、够清就跳过；关 / 轻量 / 高质量，默认关 | PR-③ 实现（§4） |

作用范围：整页 + 气泡放大层。放大层克隆的是页图（`<img>` 的 `src`），页图换成增强后的字节，
放大层自然受益；本设计不改放大层代码。

## 1. 现状（2026-11-20 代码事实）

- 页图在 WebView 里画（`manga_overlay_html.dart` 的 `mangaWindowDocument`），`<img>` 由宿主拦截器
  （`MangaFushiPage._interceptRequest`，Apple 端是 `fushi-manga://` scheme handler）供字节。
- BUG-4704 以后，本地卷 / 已下载章的页图 URL 带 `fit=<像素宽>`（页面 JS 按「排版宽 × DPR × 缩放档」
  算），拦截器经 `MangaPageFitter` 在后台 isolate 里调 Rust `ffc_image_fit_jpeg`（解码 + sRGB 面积平均 +
  JPEG）降采样。**只在省下 ≥ 36% 像素时才转**（`kMangaFitMaxPixelRatio`），否则交原图让 WebView 自己缩；
  放大（显示比原图大）一律交 WebView。
- WebView 的缩放：Chromium（WebView2 / Android WebView）对图片是 mipmap + 双线性，WebKit 类似；都在
  sRGB 编码值上算，缩小时会混叠出网点摩尔纹。
- 在线直读章（`OnlineMangaReaderSession`）的 payload 尺寸是占位值，不开 `fit=`（BUG-4704 原注释）。
- OCR 结果（`manga.json` 块 / 行几何）是**原图像素坐标**，覆盖层按 `data-pw` / `data-ph`（原图尺寸）
  做归一化；`<img>` 用 `object-fit: contain` 撑满同一个容器，所以换成任何尺寸的同比例图，OCR 框与
  查词命中都不变。

## 2. 评测（2026-11-20，本机 Windows，i5-12600KF + RTX 4070 Ti）

对比页、裁图、数字全在本地 `fushi/build/manga_upscale_eval/index.html`（不入库）。脚本在
`D:\hibiki-tmp\upscale_eval\scripts\`（`eval.py` / `eval_down.py` / `report.py`）。

**素材**：用户真实卷——《君が一等星に光るまで 01》（1350×1920，正文大字）、两章 Mihon 下载章
（1370×2000 振假名密集 / 1115×1600）、《14歳の恋 01》（972×1400 灰度，真实低清卷）。

**可读性指标**：用本仓漫画 OCR 的识别器（PP-OCRv6 漫画微调 rec，`kellenok_manga_rec_v0.2`，与 app
同输入契约）读字。参考文本 = 原图上的读数（置信 ≥ 0.85）；处理后的图在同一行框（按比例换算）上
再读一遍算字错误率（CER）。**小字** = 原图行框短边 < 30 px（振假名、旁注、拟声小字）。OCR 只是人眼
可读性的代理指标，所以同时出裁图人工看。

### 2.1 ① 显示侧缩小：哪种缩放算法

阅读器绝大多数时候是在**缩小**显示（手机竖屏 ≈ 0.8，平板横屏双页 ≈ 0.45～0.6）。5 种算法 × 4 个比例 ×
4 套书各 4～5 页：

| 0.45 倍时的 CER（小字 + 正文合计） | 面积平均（sRGB，现内核） | WebView 式（mipmap + 双线性） | Lanczos3 | 面积平均（线性光） | Lanczos3（线性光） |
|---|---|---|---|---|---|
| 一等星 | **23.7%** | 29.4% | 26.0% | **23.7%** | 26.5% |
| Mihon 振假名章 | **2.0%** | 2.1% | **2.0%** | 2.3% | 2.3% |
| Mihon 章 2 | **6.4%** | 10.7% | 6.8% | 6.5% | 7.1% |
| 14歳の恋 | 3.7% | 4.6% | 4.0% | **3.3%** | 4.8% |

结论：

- **WebView 自己缩是最差的**：0.45～0.6 倍时 CER 比面积平均高 20%～65%（一等星 0.6 倍 11.4% vs 8.1%），
  网点混叠最重。① 的主要收益就是**所有缩放都不交给 WebView**。
- **面积平均（核按比例放宽）最好**；Lanczos 笔画更黑（对比度 +5%～10%），但振铃让小字读错更多。
- **Gamma 校正（线性光）是取舍，不是白赚**：网点明度误差降约三成（网点不发闷、不变暗），但 1 像素
  细笔画缩小后变淡——文字框笔画对比度（中位明度 − 最暗 5%）降 10%～20%（0.45 倍：一等星 152 → 124，
  Mihon 章 2 173 → 147）。CER 基本持平。与「小字可读」这个第一指标冲突。
  - 可达阅读器 2.5.0 的「Gamma 校正缩放」原始更新日志没能查到原文（官网日志只到 2.1.10，1.7.1 有
    「新的渲染方案，避免高清漫画缩放产生的摩尔纹」）；它解决的是网点摩尔纹 / 发闷，这一点由「核按比例
    放宽的面积平均」已经解决，线性光只额外修网点明度。
  - PR1 时：Gamma 校正做成画质缩放下的子开关，默认关。
  - **第二轮（2026-11-21，所有者拍板按此做）：文字感知的 Gamma 校正**——OCR 文字框内 sRGB 面积平均、
    框外线性光面积平均，遮罩在目标分辨率上外扩 2 px、高斯 sigma 1.5 羽化后混合。实测（一等星 0.45 倍）：
    CER 23.66% 与 sRGB 相同、文字笔画对比度 152.4 与 sRGB 相同（整页线性光 123.9）、网点明度误差 9.1
    与整页线性光相同（sRGB 12.8），看不出接缝。对照组：线性光 + USM 锐化（对比度回来但 CER 更差）、
    gamma 1.4 / 1.7 折中（两头各丢一半）都更差。业界参照：mpv `linear-downscaling`（编码 profile 与
    Plex High 档默认开）、Artoriuz 的测量（线性光缩小让亮结构膨胀、暗结构变细——正是细黑笔画变淡）。
    见 §3.1。

### 2.2 ③ 低清源放大：哪个模型

原图面积平均缩到 1/2 后 JPEG 重压（q90 / q70）当「低清源」，放大 2 倍回原尺寸，与原图读数比（3 套书 6 页，
小字 343 字 / 正文 974 字，含振假名密集章）：

| 方法 | 小字 CER q90 | 小字 CER q70 | 正文 CER q90 | PSNR q90 |
|---|---|---|---|---|
| waifu2x swin_unet art 2x | **7.3%** | **10.5%** | **0.4%** | **27.1** |
| 双三次（基线） | 8.2% | **10.5%** | 0.8% | 22.7 |
| 双线性（WebView 放大） | 8.5% | 10.8% | 1.2% | 21.1 |
| waifu2x cunet art 2x | 9.3% | 12.8% | 0.4% | 26.6 |
| waifu2x swin_unet art_scan 2x | 16.3% | 21.9% | 0.7% | 25.1 |
| MangaJaNai 2x 1600p（CC BY-NC，仅作参照） | 20.1% | 26.5% | 0.5% | 20.3 |
| Real-CUGAN pro conservative | 23.9% | 28.9% | 0.7% | 23.3 |
| Real-CUGAN conservative | 30.0% | 32.7% | 0.9% | 23.5 |
| Real-CUGAN denoise3x | 47.8% | 48.4% | 1.7% | 22.2 |

真实低清卷（《14歳の恋》972×1400 原样放大，以原图读数为参考，小字 11 / 正文 131）：waifu2x 全系与 MangaJaNai
0 错，Real-CUGAN 各变体小字错 1～2 个。

结论：

- **Real-CUGAN 全部 5 个变体都明显损害小字**（小字 CER 是双三次的 3～6 倍）：它把细笔画 / 淡印小字
  当噪声抹平（裁图里「TEL:090-…」这类淡印小字被抹成一片灰）。这正是「可达阅读器 waifu2x 把字糊成一坨」
  那类问题。**不用 Real-CUGAN**。
- **MangaJaNai 不用**：许可证是 **CC BY-NC 4.0**（仓库 `LICENSE` 原文为
  「Attribution-NonCommercial 4.0 International」，<https://github.com/the-database/MangaJaNai/blob/main/LICENSE>），
  非商用不能随包也不能默认下载；实测它会重新「画」网点（PSNR 最低），小字也不如双三次。
- **waifu2x swin_unet art 是唯一在小字上不输双三次的模型**（q90 少错 3 个字、q70 持平），正文错误减半，
  线条 / 网点 PSNR 高 4～5 dB——它的价值主要是**画面观感**（锐利、去 JPEG 块），不是让读不出的字变读得出。
  cunet art 小字比双三次略差（q90 +1.1、q70 +2.3 个百分点），速度快 3 倍。
- 许可证：waifu2x（nunif）MIT，<https://github.com/nagadomi/nunif/blob/master/LICENSE>；ONNX 来自 nunif 官方
  `waifu2x_onnx_models_20250502.zip`（<https://github.com/nagadomi/nunif/releases/tag/0.0.0>）。
  Real-CUGAN MIT（<https://github.com/bilibili/ailab/blob/main/Real-CUGAN/LICENSE>）。

### 2.3 ③ 速度（单页，秒）

| 模型 | Windows CPU（ORT CPU EP，16 线程），675×960 输入 | 实测 972×1400 输入 | GPU（ncnn Vulkan，RTX 4070 Ti） |
|---|---|---|---|
| waifu2x cunet art 2x | 4.3～5.3 | 9.2 | < 0.5（官方 waifu2x-ncnn-vulkan，含读写） |
| waifu2x swin_unet art 2x | 12.7～14.0 | 27.5 | （ncnn 无 swin 版） |
| Real-CUGAN | 4.3～5.8 | 9.2～9.7 | < 0.5 |
| MangaJaNai（ESRGAN） | 33.6 | 63.3 | — |

- 首轮 DirectML 输出全错（Real-CUGAN 值域 72～217、waifu2x 近乎全黑）。第二轮查清根因是导出图里的负 Pad，
  离线改写成 Slice 后与 CPU 一致，见 §4.3。
- CPU 上 cunet 一页约 10 秒：按学习者每页 30 秒以上的阅读速度，向后预取 2～3 页跟得上；swin_unet 一页
  约半分钟，只适合「当前页 + 下一页」，且台式机以外发热明显。

## 3. ① 默认档：画质缩放（PR1）

- 偏好 `enhancedScaling`（默认 **开**）与子开关 `gammaCorrectScaling`（PR1 默认关，§3.1 起默认 **开**），进
  `MangaReaderPreferences`（全局 + 每书覆盖同一套机制），设置面板「滤镜」页新「画质」组。
- 页图 URL：`fit=<宽>` 之外带 `fq=1`（画质缩放）/ `fq=g`（+ Gamma 校正）。**响应只由 URL 决定**，
  切开关后 WebView 的 `max-age` 缓存不会把另一档的图端回来；缓存键里也带档位。
- 文档侧取整档距：画质档 32 px（标准档仍是 128 px），WebView 自己再缩的余量 < 3%。
- 拦截器 → `MangaPageFitter`（后台 isolate、串行、按字节 LRU，同 BUG-4704）→ 新 Rust 内核
  `ffc_image_fit_jpeg_hq`（`native/fushi_compute/src/image/resample.rs`）：
  - 缩小：面积平均，核按缩放比放宽（网点不出摩尔纹）；只要与原图差出 3% 就转（不再要求省 36%）。
  - 放大：Catmull-Rom 三次，至多 2 倍、至多 1677 万像素（再大交 WebView）。
  - `flags` 位 0 = 文字感知的 Gamma 校正（§3.1）；JPEG q94、4:4:4、灰度源编单通道。
  - **源图的 ICC 配置文件原样带进输出 JPEG**（两种 fit 内核共用出口 `encode_fit_jpeg`）。真机实测：《14歳の恋》
    页图嵌了灰度配置文件，转码丢掉它以后 WebView 按未标记 sRGB 画，暗部从 12 变成 20、整页发灰；
    BUG-4704 的标准 fit 降采样也有同样问题，一并修。
- 标准档（关掉画质缩放）行为与 BUG-4704 完全相同。
- 在线直读章不开 `fit=`（尺寸是占位值），画质缩放对它暂不生效；下载后的章生效。

### 3.1 ④ 文字感知的 Gamma 校正（PR-④，叠在 PR1 上）

- 内核：`ffc_image_fit_jpeg_hq` 加 `text_boxes: *const f32` + `text_box_count`（归一化 `[x0, y0, x1, y1]`，
  至多 4096 个），`flags` 位 0（`FIT_HQ_TEXT_AWARE_GAMMA`）开时：同一核分别在 sRGB 与线性光里重采样，
  按文字遮罩（目标分辨率外扩 2 px、可分离高斯 sigma 1.5）逐像素混合（`resample.rs`
  `resample_text_aware`）。**框列表为空 = 整页 sRGB**：没有 OCR 数据的页不知道字在哪，不冒险让笔画变淡。
- 文字框取本页 OCR **块框**（`MokuroBlock.rectangle`，按 `page.size` 归一化）：气泡里整块都是字，块框把
  振假名、标点、行间一起罩住；外扩与羽化交内核按目标分辨率做。
- 子开关 `gammaCorrectScaling` 改为默认开、文案「Gamma 校正网点（有 OCR 的页文字保持锐利）」（只改
  值，`i18n_sync --set`；键不变，PR1 未合入、没有存量偏好）。
- 缓存一致性：页 div 带 `data-tb=<框签名>`（框数 + FNV-1a），`_refitPage` 在 `fq=g` 时把它挂成
  `tb=`；`MangaPageFitter` 的缓存键同样带签名。后台 OCR 补完一页时 `__mangaReplaceOcr` 收到新签名，
  变了就重设页图 src——WebView `max-age` 缓存与 LRU 都不会把无框（整页 sRGB）的旧图端回来。
- 拦截器按**当下的** `_payload.images[pageIndex]` 取框；页号不明（目录兜底路径找不到页号）按无框处理。

## 4. ③ 低清页 AI 超分（PR-③）

所有者拍板（2026-11-21）：按「OCR 框融合」做——框内用对小字最安全的方法、框外用观感最好的模型，羽化遮罩混合；
设置「关 / 轻量 / 高质量」，默认关。

### 4.1 两档的模型与 OCR 框融合

| 档 | 框外（网点 / 线条） | 框内（文字） | 没有 OCR 的页 |
|---|---|---|---|
| 轻量 | ArtCNN C4F32（2x，感受野小、快） | Catmull-Rom 2x | **跳过**（走 ① 画质缩放） |
| 高质量 | waifu2x swin_unet art noise1_scale2x | waifu2x swin_unet art scale2x | **整页 scale2x** |

- 遮罩：每个 OCR 块矩形外扩 2 px 后高斯羽化（σ = 1.5，输出像素），`out = 框内结果 × m + 框外结果 × (1 − m)`
  （与 ④ 的 Gamma 校正同一套遮罩，`native/fushi_compute/src/image/resample.rs`）。高质量档框内模型只跑与框相交的块。
- 没有 OCR 的页：轻量档框内外都要靠「框」区分，没有框就没有安全的文字区，ArtCNN 整页会轻微重画小字，所以跳过、交给 ①；
  高质量档的 scale2x 在 §2.2 小字上不输双三次，整页用它是安全的。
- 灰度页按单通道进出（模型吃三通道时复制三份、出来取均值）；彩色页走 Y 通道（模型跑亮度，色度 Catmull-Rom）。
- 输出 JPEG q94，带原图 ICC；结果 2 倍大，再由 ① 的画质缩放按显示宽度缩（URL 照常带 `fit=` / `fq=` / `tb=`）。

### 4.2 引擎（Rust 胖核心，`native/fushi_compute/src/upscale*`）

- 进程级单例：ORT 运行时、模型会话、任务队列、磁盘 LRU、一个工作线程。Dart 只发粗粒度命令
  （`ffc_upscale_start / configure / submit / query / focus / clear / cached_path / backend_available / tier_supported`），
  事件经 Dart 原生端口发回（`done / skipped / failed / cancelled / models_failed`；BUG-5413 起不用 `NativeCallable.listener`，
  见 `native/fushi_compute/src/dart_port.rs`），不存镜像状态。
  「正在算 / 判过不做 / 失败过」也由引擎记（`query`），换配置清零；调用方据此决定要不要读原图来提交。
- **ORT 不另带**：dlopen 本进程已有的那份（Windows = flutter_onnxruntime 插件绑定的那个 `onnxruntime.dll`——下载的
  DirectML core 被选中时是它，否则随包 CPU core；Android = AAR 的 `libonnxruntime.so`；Apple = 静态链进主程序的那份，从
  本进程符号找，macOS 实测主程序导出 `_OrtGetApiBase`），`ort` crate `alternative-backend` + `api-23`（要求 ORT ≥ 1.23）。
  Windows 用 `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` 加载，DirectML core 旁的 `DirectML.dll` 能被找到。
- **分块推理与接缝**：块形状恒定（DirectML 只按一个形状编译），反射填充，硬裁有效区。实测（972×1400 真实低清页，交界
  一像素跳变 / 非交界对照列，> 2 即肉眼可见台阶）：

  | swin 块 / 上下文 | 跳变比 |
  |---|---|
  | 256 / 16（旧设计） | ≈ 10 |
  | 256 / 64 | ≈ 10（加大上下文无效） |
  | **384 / 64（采用）** | noise1 0.11 / scale2x 0.23 |

  根因：swin 的输出依赖整块统计（窗口注意力 + 块内归一化类算子），块小时块与块之间系统性偏移，加上下文消不掉；块到 384
  后偏移落进噪声。ArtCNN 感受野小，上下文 ≥ 8 起与整张推理逐像素一致（只差图像边界），采用块 512 / 上下文 16。
  回归测试：`real_model_swin_tiles_have_no_visible_seams`（真模型，env 门控）+ `tiles_with_enough_context_have_no_seams`
  （模拟网络，含短上下文的反例，CI 跑）。
- **队列**：优先级 = 离当前页的距离（往后 d×2、往回 |d|×8+1），保留窗口 [当前−1, 当前+预取]，翻走的任务丢弃（发 cancelled）；
  预取页数轻量 3 / 高质量 2。
- **磁盘缓存**：`<app cache>/manga_upscale/`，上限 1 GB，按 mtime LRU（命中即刷新），写临时文件再改名。键 =
  `模型版本 | 档 + 文字框签名 | 卷作用域 | 会话页身份`——后台 OCR 补完框后签名变，旧结果不再匹配、重做。
- **跳过**：显示宽度 < 原图宽 × 1.1 不提交（原图像素已够屏幕用，超分没有收益；放大查看时显示宽度变大，自然会做）；
  结果超过 48 M 像素不做。

### 4.3 后端与实测（972×1400 灰度页，两块对话框，单页秒数，`real_model_page_timing`）

| 平台 / 后端 | 轻量 | 高质量 | 说明 |
|---|---|---|---|
| Windows DirectML（i5-12600KF + RTX 4070 Ti，ORT 1.24.4 DML core） | **0.27** | **5.5** | 需要「GPU 加速运行时」包（已有）；会话加载 0.5 s / 5.8 s |
| Windows CPU（随包 ORT 1.31，6 线程） | 0.56 | 87 | 没有 DML 包时只给轻量档 |
| macOS CoreML（Apple M4，ORT 1.23，MLProgram） | **0.24** | 不可用 | swin 在 CoreML 上建不了会话（见下） |
| macOS CPU（M4，6 线程） | 0.73 | 50 | |
| Android | 未实测（无真机） | 不提供 | 先 CPU 轻量档 |

- **DirectML 输出与 CPU 一致**（`real_model_accelerated_backend_matches_cpu`）：scale2x / noise1 / ArtCNN 最大差 0 / 1 / 1（0～255），
  均值 0.0000。§2.3 的「DML 输出全错」根因是 nunif 导出图里的**负 Pad**（用 Pad 做裁剪）在 DML EP 上算错；发布前用
  `fixpad.py` 把负 Pad 离线改写成 Slice（数学等价，CPU 上与原图逐元素一致），**不在用户机器上改写**。
- **CoreML**：ORT 1.23 的 CoreML EP 默认 NeuralNetwork 格式建 ArtCNN 会话直接段错误；MLProgram 正常，与 CPU 最大差 1、均值 0.0000。
  swin 两个模型在 MLProgram 下报「Failed to build the model execution plan … error code: -14」（ALL / CPUAndGPU / CPUOnly 都一样）。
  所以 Apple 只给轻量档（CoreML）；高质量档在 Apple 上用 CPU 一页 50 s，不提供。
- 档位 × 后端的取舍只在引擎写一次（`tier_supported`：高质量档只在 DirectML 上）；Dart 选了高质量但后端不支持时，下载模型前就降到
  轻量并提示一次。
- 高质量档一页 5.5 s：学习者每页 30 s 以上，预取 2 页跟得上；当前页首次打开要等一页的时间（期间显示 ① 的结果，好了再换图）。

### 4.4 模型发布与下载

- 模型不进安装包，首次选该档时按需下载，钉 SHA-256 与字节数：本仓预发行
  [`upscale-models-v1`](https://github.com/hajisensai/Fushi/releases/tag/upscale-models-v1)。

  | 文件 | 用途 | 字节 | SHA-256 |
  |---|---|---|---|
  | `ArtCNN_C4F32.onnx` | 轻量框外 | 193085 | `b1a11304…f6ea` |
  | `swin_unet_art_scale2x.onnx`（Pad 已改写） | 高质量框内 / 无 OCR 整页 | 16734898 | `490be499…a30a` |
  | `swin_unet_art_noise1_scale2x.onnx`（Pad 已改写） | 高质量框外 | 16734898 | `750be49b…1d2c` |

- 许可：waifu2x / nunif MIT，ArtCNN（Artoriuz/ArtCNN v1.6.2）MIT，许可证原文与 `fixpad.py` 随发行附带。
- 下载走 `ModelFileDownloader`（系统代理、`.part` 续传），完成后在后台 isolate 校验 SHA-256，不符即删并报不可用。
  落 `<app support>/manga_upscale_models/v1/`。换模型 = 新版本目录 + 新缓存键前缀。

### 4.5 阅读器接线与 OCR 坐标

- 拦截器看到某页以 `fit=W` 被请求、且 W ≥ 原图宽 × 1.1 → 提交；当前页变化 → `focus` + 往后预取。完成事件 → 页面脚本
  `__mangaSrReady(page, url)` 把 `<img data-src>` 换成带 `sr=<档+框签名>` 的 URL 并按当前显示宽度重取。整页与**气泡放大层**
  （克隆页、读 `data-src` 取全分辨率图）都从这个 URL 取图；拦截器按 `sr=` 从缓存取超分图当源（带 `fit=` 的照常缩放），结果被淘汰
  则退回原图且 `no-store`。重建窗口文档时已在缓存里的页直接带 `sr=`。
- OCR 一律在原图上跑、存原图坐标；页 div 的 `data-pw` / `data-ph` 不变，图按 `object-fit: contain` 铺满，**查词命中不受影响**
  （真 app 实测见 §4.7）。
- 在线直读章不做（页图是会话私有的临时文件）。

### 4.6 设置项（漫画阅读器 › 滤镜 › 画质）

- 画质缩放（默认开）/ Gamma 校正网点（文字感知，默认开）— PR1 / PR-④。
- 低清页 AI 超分：关 / 轻量（快）/ 高质量（需 Windows GPU），默认关 — PR-③。

### 4.7 验证

- Rust：`cargo test --profile quick --lib upscale`（Windows / macOS 各 17 条）；真模型（env 门控）接缝、加速后端对 CPU、单页耗时见上。
- Windows 真 app（`integration_test/manga_enhanced_scaling_itest.dart`，`MANGA_AI_UPSCALE=light|high|off`）：页图换成 `sr=`、
  `data-src` 带 `sr=`、1x 与 250% 放大下点 OCR 首字命中。超分只在显示宽 ≥ 原图 × 1.1 时做，测试先放大到 250% 再等结果
  （100% 下是否满足取决于屏幕 DPR）。实测（含首次下模型）：轻量 CPU 1.6 s、高质量 DML 17.4 s 后换图。
- 未验证：Android（无真机）、iOS（符号导出只在 macOS 主程序上确认过）、气泡放大层的真截图（放大层代码在 #3839，本分支没有；
  只验证了它读的 `data-src` 已是超分 URL）。

### 4.8 与在线漫画 / 互联漫画 / iOS 合规的关系

- **互联漫画**：页图经互联拿到本地后与本地卷同路径，在阅读端本机算，不改互联协议、不上传。
- **iOS 合规**：纯本地图像处理，不属于 `StoreRestrictedCapability` 的三类能力；模型下载是本地功能的资源下载（同 OCR 模型）。

## 5. 性能目标

- ①：每页一次转码（解码 + 重采样 + JPEG），后台 isolate 串行；单页耗时 PR1 未单独测（量级为一次 JPEG 解码 + 编码），
  不在 UI isolate。
- ③：实测见 §4.3——轻量档各平台单页 0.2～0.7 s；高质量档只在 Windows DirectML 上提供，单页约 5.5 s，预取 2 页。工作线程是引擎自己的原生线程，不占 UI isolate。
