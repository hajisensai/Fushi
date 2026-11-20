# 漫画阅读器画质增强 / 超分设计（2026-11-20）

所有者已拍板的方向：给漫画阅读器做「超分 / 画质增强」，**第一评价指标是小字 / 假名的可读性**
（看漫画是为了看清字、查词），其次才是线条观感。分三档，本轮做 ① ③，② 往后放。

| 档 | 内容 | 状态 |
|---|---|---|
| ① 默认档（零开销） | 更好的缩放算法 + 文字感知 Gamma 校正，所有平台、默认开 | PR1 + PR-④ 实现 |
| ② 轻量实时档 | （往后放，不做） | — |
| ③ 高质量档（离线） | 神经网络超分逐页处理，向后预取、落盘缓存、够清就跳过；默认关 | PR2 实现，模型按本文实测结论选 |

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

- **DirectML 不可用**：同一批模型在 ORT DirectML EP（1.24.4，即 app 的 Windows GPU 运行时包那一版）上
  输出全错（Real-CUGAN 值域 72～217、waifu2x 近乎全黑），同机 OCR 检测模型在 DML 上与 CPU 一致——是这几个
  超分图在 DML 上的算子问题（未深挖到具体算子）。
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

## 4. ③ 高质量档：离线超分（PR2）

### 4.1 选型

- 默认模型 **waifu2x swin_unet art 2x（`scale2x`）**：唯一在小字上不输双三次的模型（q90 / q70 都持平略好）、
  观感 +5 dB；代价是 CPU 一页约半分钟，只预取下一页、适合台式机。可选 **cunet art 2x**（快 3 倍，q90 持平、
  q70 小字略差，GPU 后端可用后再考虑作默认）。不提供 Real-CUGAN（小字实测明显变差）。
- 模型不进安装包，按需下载（同 OCR 模型：Hugging Face / GitHub 官方地址 + 钉 SHA-256，进
  「设置 › 存储」可删）。

### 4.2 推理后端

| 平台 | 后端 | 说明 |
|---|---|---|
| Windows | ORT CPU EP | DML 实测输出错误（§2.3），不用；CUDA 运行时包已装时可用 CUDA EP |
| macOS / iOS | ORT CoreML EP（ANE / GPU），CPU 兜底 | 需真机验证算子覆盖 |
| Android | ORT XNNPACK / CPU | NNAPI 对动态尺寸支持差，先 CPU |
| Linux | ORT CPU | |

- **复用现有 ONNX 基建**：本仓 ONNX 推理目前全在 Dart 侧（`flutter_onnxruntime` 插件 + `OcrInference`
  抽象），没有 Rust 侧 ort 依赖。新 crate 用 `ort`（`load-dynamic`）加载**进程里已有的那份
  onnxruntime 动态库**（插件随包的 CPU core；Windows 上若用户装了 DML 运行时包则是 DML 版 core，但不开
  DML EP），不另带一份 ORT。
- 新 crate `native/fushi_upscale`（C ABI `fup_*` + `packages/fushi_upscale` Dart FFI），Rust 持有状态：
  任务队列（优先级 = 离当前页的距离）、分块推理（块 256 + 上下文 16，反射填充）、磁盘缓存与 LRU；Dart 只发
  粗粒度命令（打开 / 关闭引擎、`prefetch(当前页, 页列表)`、`lookup(页)`）并订阅一条事件流
  （`ready(page, path)` / `failed` / `progress`），不存镜像状态。

### 4.3 缓存 / 预取 / 跳过

- 键：`sha256(原图字节) + 模型 id + 倍率`；落 `<数据根>/manga_upscale_cache/`，上限默认 1 GB（可调），LRU 按
  最近访问淘汰；PNG 无损（再由画质缩放按显示尺寸缩）。
- 预取：当前页优先，向后 N 页（默认 1，可调 0～10），翻页即重排；离开阅读器取消排队任务。
- **跳过**：原图高度 ≥ 「最大高度」（默认 1800 px，参考 Komic 的同名开关）不超分；放大后 2 倍高超过上限
  的也不做。跳过的页直接走 ① 画质缩放。
- 页图拦截器：画质档 + 超分开着时，先查超分缓存，命中则把超分结果当源字节交给 `MangaPageFitter`；未命中就
  先给 ① 的结果，并在超分完成后热替换当前页 `<img>`（只换 `src`，OCR 覆盖层不动）。

### 4.4 OCR 坐标

- OCR 一律在**原图**上跑、结果存原图坐标（不变）。覆盖层按原图尺寸归一化，`<img>` 换成 2 倍图后仍按
  容器 `object-fit: contain` 铺满，**查词与气泡定位不受影响**，无需换算。
- 唯一需要换算的地方：若将来要在超分图上做二次识别 / 裁图，坐标 × 倍率（`scale = 超分图宽 / 原图宽`）。

### 4.5 设置项（漫画阅读器 › 滤镜 › 画质）

- 画质缩放（默认开）/ Gamma 校正网点（文字感知，默认开）— PR1 / PR-④。
- AI 超分（默认关）、模型（cunet / swin_unet）、最大高度（默认 1800）、预取页数（默认 1）、缓存上限
  （默认 1 GB）— PR2。

### 4.6 与在线漫画 / 互联漫画 / iOS 合规的关系

- **在线直读章**：页图来自会话私有缓存，尺寸不可信，① 不生效；③ 可以对已取到的页字节超分（不依赖尺寸），
  PR2 先只做本地卷与已下载章，在线直读后续再接。
- **互联漫画**（从另一台设备读）：页图经互联拿到本地后与本地卷同路径，①③ 都在**阅读端**本机算，不改互联
  协议、不上传。
- **iOS 合规**：超分是纯本地图像处理，不属于 `StoreRestrictedCapability` 的三类能力；模型下载是本地功能的
  资源下载（同 OCR 模型），iOS 照常提供。

## 5. 性能目标

- ①：每页一次转码（解码 + 重采样 + JPEG），后台 isolate 串行；单页耗时 PR1 未单独测（量级为一次 JPEG 解码 + 编码），
  不在 UI isolate。
- ③：Windows 台式 CPU 单页 ≈ 28 s（swin_unet）/ ≈ 10 s（cunet），默认预取 1 页；移动端只在充电 / 不过热时默认预取（PR2 实测后定）。
