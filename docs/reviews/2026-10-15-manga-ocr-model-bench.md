# 漫画本地 OCR 模型对拍：删 Baberu、候选模型复测（2026-10-15）

起因：用户问「Baberu 真比漫画 CTC 好吗」，要求实测，不行就删，并顺带试其它模型。此前 Baberu 与 CTC 从未在同一批素材上直接比过（[2026-09-23](2026-09-23-manga-ocr-options.md) 只比了 Baberu vs manga-ocr 的 16 框，[2026-09-30](2026-09-30-manga-ocr-select-speed.md) 只比了 CTC vs manga-ocr）。

## 测量方法

- **素材**：用户书架里《幼なじみが絶対に結ばれる百合アンソロジー》全部 166 页（多位作者合集，画风/字体差异大）。原 9-30 评测用的《君が一等星に光るまで》已不在本机。
- **参照**：同书已有的 Google Lens 逐字框结果（`manga_ocr_out/_pages/google-lens-v2-niratan-ja`）。振假名按「假名且横向尺寸 < 块内中位字宽 0.6」剔除。Lens 不是人工真值（拟声词/手写它也错），**只看横向比较**。
- **指标**：
  - 块级 CER：预测的行框（有 `lineBoxes` 时逐列）或块框面积一半以上落在某个 Lens 块里就归给它，按阅读序拼接后算编辑距离 / 参照字数。「正文」口径只留字母、数字、ー（NFKC 后），另给全字符口径。**预测单元比 Lens 块大（跨多个气泡）时这个指标失效**，此时只看下一项。
  - 整页字符袋召回/精确：与检测框、阅读序无关的交叉检查。
- **app 管线**：`packages/fushi_server` 的 `installServerHostBindings` + `MangaOcrServiceImpl.ocrFolder` 整卷任务，FFI ORT（`D:\APP\Hibiki\onnxruntime.dll`），与无头服务端同一接线；页图复制到临时目录，不写用户书目录。
- **候选识别器**：Python ORT 1.22 CPU、4 线程，按各模型参考实现重写预处理（Baberu 对齐 `baberu_ocr_recognizer.dart`；PP-OCR rec 对齐 `ppocr_line_recognizer.dart`；nar-small 按其 `preprocess.py`）。
- 测量期间多个任务并发抢 CPU，**耗时只看相对值**。评测脚本与输出在会话临时目录，不入库。

## 1. Baberu vs 漫画 CTC（app 真实管线）

| 166 页整卷 | 正文 CER | 块全对 | 字召回 | 字精确 | 整卷耗时 |
|---|---:|---:|---:|---:|---:|
| **漫画 CTC（Kellenok v0.2 逐列）** | **13.8%** | **78.9%** | **93.5%** | **93.1%** | **146 s** |
| Baberu v1.0（app 钉的 `d9cc131`） | 21.0% | 73.1% | 87.9% | 92.3% | 453 s |

Baberu 更不准、慢约 3 倍、只有 Windows、下载 271 MB（CTC 约 40 MB）。**结论：删除 Baberu。**

拆因：同一个 Baberu 识别器吃 Lens 理想块框时正文 CER 10.7%、召回 92.4%——它在 app 里吃亏主要在检测/裁块（召回 87.9%），不是识别器本身。但即便修好那条路径，它也只是追平 CTC 的量级，且慢、单平台，不值得保留。

## 2. 候选模型复测

同一批 2500 个 Lens 理想块框（漫画 CTC 走引擎的文字图识别入口 `recognizeTextImage`，即真实的 `CtcColumnOcrRecognizer`：块内行检测、定方向、滤振假名列、逐列识别）：

| 识别器 | 正文 CER | 全字符 CER | 块全对 | 字召回 | 字精确 | 耗时（并发下） |
|---|---:|---:|---:|---:|---:|---:|
| **漫画 CTC（Kellenok v0.2 逐列）** | **5.57%** | 11.99% | **87.9%** | 95.7% | **97.5%** | **43 ms/块** |
| [manga-ocr-nar-small](https://huggingface.co/muscgab/manga-ocr-nar-small) `be49498`（NAR，单次前向） | 5.82% | **11.04%** | 87.7% | **95.9%** | 96.6% | 200 ms/块 |
| Baberu v1.1 `fbcd115` | 10.61% | 17.39% | 84.6% | 92.4% | 94.2% | 347 ms/块 |
| Baberu v1.0 `d9cc131` | 10.67% | 16.17% | 84.8% | 92.4% | 94.4% | 347 ms/块 |

**理想框上漫画 CTC 与 nar-small 打平**（正文口径 CTC 略好，含标点口径 nar 略好，差距都在 1 个百分点内），CTC 快约 4–5 倍。CTC 在 app 管线里的 13.8% 与这里的 5.6% 之差来自检测/切块，不是识别器。

CTC 行识别器之间的比较（Lens 逐字框拼出的行框，同一切分）：

| 行识别器 | 正文 CER | 块全对 | 字召回 | 耗时（并发下） |
|---|---:|---:|---:|---:|
| Kellenok v0.2 | 15.2% | 81.9% | 86.0% | 22 ms/行 |
| PP-OCRv6 medium rec 原版 `50c7eac` | 18.7% | 77.4% | 83.2% | 72 ms/行 |

- **Baberu v1.1 ≈ v1.0**：视觉编码器字节相同，只换了 step 解码器（长气泡），本书上无差别。
- **PP-OCRv6 medium 不如 Kellenok small**：同词表（18708 项，可直替），但未经漫画微调，更不准且慢 3 倍。不换。
- Lens 行框是从逐字框拼出来的，会漏字（Kellenok 在这里召回只有 86%，低于它在 app 管线里的 93.5%），所以这张表只用于 CTC 行识别器之间比较，不能与上表的块级结果相比。

**nar-small 换进 app 管线**（只换识别器，检测/切分不变）：

| 吃 app CTC 管线的框 | 正文 CER | 字召回 | 字精确 | 耗时 |
|---|---:|---:|---:|---:|
| 漫画 CTC（现状） | 13.8% | 93.5% | 93.1% | ~11 ms/列 |
| nar-small 吃同一批**列框** | 14.5% | 93.3% | 92.7% | ~100 ms/列 |
| nar-small 吃同一批**块框** | —（块跨气泡，CER 失效） | 86.9% | 93.2% | 111 ms/块 |
| Baberu v1.1 吃同一批块框 | — | 87.1% | 91.3% | 207 ms/块 |

无论理想块框、app 的列框还是 app 的块框，nar-small 都没有超过漫画 CTC，却慢 4–10 倍、大 5 倍（213 MB）、权重 CC BY-NC-SA 4.0；吃 app 的块框时还会掉字（app 检测器给的块常跨多个气泡，nar 单框最多 64 字）。**不引入。** 若以后要再提精度，杠杆在检测/切块，不在识别器。

未实测：manga-ocr-mobile（卡片自报 Manga109 CER ~7.4%，弱于 Kellenok 自报 5.63%，TF 转出的编码器归一化不明）、Hayai v2.5 Nova ONNX 移植（157M 自回归，CPU 延迟预计数百 ms/块，只适合 GPU 档）、PaddleOCR-VL 等 ≥0.9B VLM（不适合端侧逐块）。

## 3. 结论

1. 删除 Baberu 本地模型；本地模型只剩漫画 CTC（旧偏好 / 备份里的 `baberu` key 落回 CTC；互联对端显式点名 `baberu` 时 host 回 `unknown_model`，与已删的 `manga_ocr` 一致；`ocr_models/manga-baberu` 启动时清理）。
2. 漫画 CTC 保持现状：本轮没有在相同切分上比它更准的识别器（nar-small 在理想框上与它打平但慢 4–5 倍）。再提精度的杠杆在检测/切块。
3. 许可提醒仍有效：Kellenok 训练数据含 AnimeText（CC BY-NC-SA），nar-small 权重本身就是 CC BY-NC-SA。
