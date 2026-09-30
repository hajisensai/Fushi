# 漫画本地 OCR：选词不准与速度慢的根因、实测与选型（2026-09-30）

起因：用户反馈「漫画 OCR 选词不准确、速度慢，看看要不要换模型换方案」。当天用户刚用本地 ONNX（经典 manga-ocr）整卷识别《君が一等星に光るまで 01》183 页。本文只记实测结论；修复见 [BUG-2813](../bugs/BUG-2813-manga-local-ocr-tap-column.md)。

## 测量方法

- **真值**：Google Lens 的逐字框（`manga_ocr_out/_pages/google-lens-v2-niratan-ja/*.json` 的 `regions`）。Lens 不是人工真值，但对印刷体台词可靠；拟声词、手写、旋转英文上它自己也会错，所以绝对 CER 偏高，**横向比较才有意义**。
- **选词指标**：对每个 Lens 字框中心模拟一次点击，按覆盖层真实的命中规则（`_hitOcrChar`：取包含点击点的最小字框）求出选中的字；本地文本与 Lens 文本对齐后，判「选中的位置是不是这个字」。振假名逐字剔除（假名且字框明显窄于块内中位字宽），参考方向跟随 Lens 块。
- **数据**：set1 = 用户这本书 80 页（Lens 与本地结果都有）；set2 = mihon 阅读缓存里另外两章在线漫画 21 页（转生史莱姆 / 海贼王，注音多、气泡宽扁），本地结果用真实 Dart 全管线（`MangaOcrPipeline` + FFI ORT）当场跑出。
- 脚本、原始输出与模型都在本机 `D:\hibiki-tmp\mocr\` 与会话 scratchpad，不入库（含版权页图）。

## 1. 选词不准：几何，不是模型

本地 ONNX 每块只产一串文本、没有行坐标，覆盖层把字沿整块均铺。set1 64% 的块是多列/多行。

| | set1 | set2 |
|---|---:|---:|
| 修复前（整块均铺） | 14.0% | 8.2% |
| 修复后（真实 Dart 实现） | **87.3%** | **69.7%** |
| 参考：按 Lens 真列 + 真字数切分的上限 | 85.8% | — |

修复路径试过的变体（set1 / set2，Python 原型）：投影法切列 53.8%；按墨迹切字格 76%；只按 0.6 滤注音 82.8% / 49.3%；加注音侧规则、字格权重后 85.8% / 51.2%；再加长度加权方向投票 87.7% / 69.2%。换 Kellenok 漫画检测器切列效果相当（快约 5 倍，但检测不是瓶颈），没有换。

同类产品：Chimahon 按行/列框均分；Mangatan 的本地（Hayai）路径把整块当一行——与修复前的我们同构。

## 2. 速度：慢在哪

- 用户机（i5-12600KF，Windows 2 线程）实际：183 页 16 分 15 秒，中位 **5.3 s/页、0.81 s/块**。
- 原因：manga-ocr ONNX 导出**没有 KV cache**，beam 4 每步整序列重跑、cross-attention 的 K/V 每步对 197 个 encoder token 重算；且 app 经插件 MethodChannel 每步把 2.4 MB 隐状态送进去、把整块 logits 拷回来，平均每块约 58 MB 过通道。

## 3. 方案 A：原版 manga-ocr + KV cache（输出逐 token 不变）

新导出（`cross_kv.onnx` 9.5 MB + `decoder_kv.onnx` 89 MB，fp32、opset 17、只含标准算子；encoder 沿用现有 343 MB）：

- 240 块（177 页）上与 HF `generate`、现有无 cache ONNX **逐 token 240/240 一致**（beam 4）；ORT 1.22 / 1.23 结果字节相同。
- Python ORT、2 线程、beam 4：每块 **504–685 ms → 298–344 ms**；4 线程 329–431 → 185 ms。KV 后 encoder 占 55–60%，beam 4 与 greedy 每步几乎一样快（不必为速度改 greedy：greedy 与 beam 4 只有 201/240 块相同）。
- 每块跨 Dart/原生数据：约 58 MB → 约 1.4 MB（past / cross 各打包成一个句柄，beam 重排在图内 Gather）。
- 落地需要：① 两个新文件的托管地址（现有模型从 HF `mayocream/manga-ocr-onnx` 固定 revision 下载）；② 能把输出留在原生侧的 run 接口——插件的 `OrtValue` 本就是原生句柄，但 `OnnxSession.run`（外部仓 fushi-subtitles 的 `fushi_asr_core`）进出都是 Dart 张量；③ `beam_search.dart` 每步给出来源 beam。
- 顺带发现：`kRecEncoderTokens = 196` 实为 197（常量未被用到）；Dart 后处理缺原版 manga-ocr 的 `jaconv.h2z(ascii, digit)`，ONNX 路径输出 `!`、CUDA 路径输出 `！`。

## 4. 方案 B：换 CTC 漫画识别器（PP-OCRv6 系，逐列识别）

候选：PP-OCRv6 small 原版（已随包，横排路径在用）、[fumetodev/PP-OCRv6_small_rec_manga_ONNX](https://huggingface.co/fumetodev/PP-OCRv6_small_rec_manga_ONNX)（Apache-2.0，21 MB，同输入契约同字典的直替）、[Kellenok/PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) v0.2（Apache-2.0，21 MB / fp16 10.6 MB；卡片自报 Manga 集 CER 5.63%，Hayai nova 7.02%；训练数据含 Manga109-s 与 AnimeText，数据来源是否允许随 app 分发需所有者判断）。

set1（485 块、5564 个参考字，参考为 Lens）：

| 识别器 | CER | 整块全对 | 耗时 |
|---|---:|---:|---:|
| manga-ocr（用户现有结果） | 15.82% | 64.1% | ~800 ms/块（app 内） |
| PP-OCRv6 small 原版 | 16.16% | 60.4% | 11 ms/列 |
| fumetodev 漫画版 | 15.53% | 63.1% | 11 ms/列 |
| **Kellenok v0.2** | **14.86%** | **64.7%** | 11 ms/列 |

- Kellenok 的小假名（ありゃ / よぉ）、「」、英文标题、♪ 都对；5111 个输出字里非 CP932 字只有 1 个（♬），**没有简体 / 异体字形问题**。
- CTC 帧位置直接给出逐字位置：set1 点字率 **85.9%**（与方案 A 修复后的 87.3% 同档）。
- **弱点是振假名与方向**：set2 注音密集，CTC 会把没滤掉的注音列读进正文（「ここが**ねんいじょうまえ**二千年以上前…」），manga-ocr 训练时就学会忽略注音；块方向判错时 CTC 整块乱码，manga-ocr 对方向不敏感。set2 上 manga-ocr 文本明显更干净。

## 5. 建议

1. **几何修复（已做）** 是「选词不准」的主因修复，所有本地模型（经典 / Baberu / CUDA）都受益，已识别的卷开书时自动只补几何、不重认。
2. **提速首选方案 A**：输出不变、每块约 2 倍（app 内还省掉每块约 57 MB 的通道拷贝），但要先定新模型文件托管在哪。
3. **方案 B 作为可选「快速」本地模型**而不是默认：在注音少的书上又快又准，在注音密集的书上文本不如 manga-ocr；是否采用 Kellenok（数据来源）还是 fumetodev（略差但更干净）需所有者定。
4. 仍需另立的问题：macOS 插件在主线程同步推理（整卷 OCR 会卡 UI，调研结论，未实测）。
