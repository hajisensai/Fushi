# OCR DirectML 能力探针（BUG-2050）

回答一个问题：**某个 ONNX 模型在本机 ORT 的 DirectML EP 上到底能不能建出会话，
建得起来的话比 CPU 快多少。**

存在的理由：`fushi/lib/src/ocr/ocr_inference.dart` 的 Windows EP 偏好表写着
「不要 DirectML」，依据是 2026-09-02 的实测。那条注释同时写了「要改回来先重新
拿数」——这个目录就是拿数的量具。没有它，那句话是空的。

不参与任何构建，不被 app 引用；手动编译、手动跑。

## 它分三段，互不推断

| 段 | 问题 | 为什么必须分开 |
|---|---|---|
| ① `GetAvailableProviders()` | DML **编译**进当前运行时了吗 | 编译进来 ≠ 能建出会话。这是必要不充分条件 |
| ② `D3D12CreateDevice` | 这台机器**此刻**建得出 D3D12 设备吗 | 本机 GPU 客户端饱和时任何新进程都建不出（`E_OUTOFMEMORY 0x8007000E`），会伪装成模型问题，且会自行波动 |
| ③ `Ort::Session(DML)` / `(CPU)` | 这个**模型**在 DML 上成立吗，快多少 | 只有 ①② 都过了，③ 的失败才能归因到模型 |

DML 会话选项严格复刻
`third_party/flutter_onnxruntime/windows/src/dml_provider.cc`：
`ORT_SEQUENTIAL` + `DisableMemPattern` +
`OrtDmlApi::SessionOptionsAppendExecutionProvider_DML(0)`。改了那边，这边要跟着改。

## 跑法

运行时用与 `third_party/flutter_onnxruntime/windows/CMakeLists.txt` **同一组
SHA-256 钉死的 nupkg**，所以探针里的字节和 app 构建产出的完全一致。版本号和
哈希以那个 CMakeLists 为准，下面的值是 2026-09-02 的快照。

```bash
# 1) 取运行时（本机需要代理见 CLAUDE.local.md）
curl -L --proxy http://127.0.0.1:34151 --ssl-no-revoke -o ort-dml.nupkg \
  https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/1.22.0/microsoft.ml.onnxruntime.directml.1.22.0.nupkg
curl -L --proxy http://127.0.0.1:34151 --ssl-no-revoke -o directml.nupkg \
  https://api.nuget.org/v3-flatcontainer/microsoft.ai.directml/1.15.4/microsoft.ai.directml.1.15.4.nupkg

# 必须核对，否则测的不是 app 会用的那份字节
sha256sum ort-dml.nupkg directml.nupkg
# 29F9872D786236B79AA83F94482F3A17C14297E4833768D6D0ED4883EE732E60  ort-dml
# 4E7CB7DDCE8CF837A7A75DC029209B520CA0101470FCDF275C1F49736A3615B9  directml

unzip -q ort-dml.nupkg -d ort && unzip -q directml.nupkg -d dml

# 2) 取模型（清单见 fushi/lib/src/ocr/manga_ocr_model_manifest.dart）
curl -L --proxy http://127.0.0.1:34151 --ssl-no-revoke -o detector-v4-s_int8.onnx \
  https://huggingface.co/ogkalu/comic-text-and-bubble-detector/resolve/main/detector-v4-s_int8.onnx
```

编译（MSVC；`/utf-8` 不能省，否则本文件的中文注释会被按 GBK 解释、编译报一串
莫名其妙的语法错误）：

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cl /nologo /EHsc /std:c++17 /O2 /utf-8 /I ort\build\native\include probe.cpp ^
   /link /OUT:run\probe.exe ort\runtimes\win-x64\native\onnxruntime.lib d3d12.lib dxgi.lib
```

跑（三个 DLL 必须和 exe 同目录）：

```bash
cp ort/runtimes/win-x64/native/onnxruntime.dll run/
cp ort/runtimes/win-x64/native/onnxruntime_providers_shared.dll run/
cp dml/bin/x64-win/DirectML.dll run/
run/probe.exe detector-v4-s_int8.onnx
```

## 怎么读结果

**一个模型的一次观测不足以下结论**，必须有同架构对照组把变量隔离出来。
2026-09-02 那次就是靠 fp32 对照才把「是这台机器坏了」排除掉的：

```
                     DML 建会话        DML 稳态   CPU 建会话   CPU 稳态
int8（出包用）       ❌ 1547ms 后失败   —          734ms        81.5ms
fp32（对照组）       ✅ 2957ms          21.6ms     1461ms       419.4ms
```

fp32 在同一台机器、同一个运行时上建得起来且比 CPU 快 19.4 倍 ⇒ 不是显卡、
不是打包、不是 D3D12 ⇒ **变量精确就是 int8 量化**。

失败长这样，`80070057` 是 `E_INVALIDARG`：

```
ortErrorCode = ORT_RUNTIME_EXCEPTION
message      = Exception during initialization: ...\DmlExecutionProvider\src\
               MLOperatorAuthorImpl.cpp(2851)\onnxruntime.dll!...: 80070057
```

顺带记一笔：int8 在 **CPU** 上反而比 fp32 快 5 倍（81.5ms vs 419.4ms），
这就是当初选 int8 小档（11MB vs 168MB）的原因。fp32+DML 稳态虽然更快
（21.6ms），但建会话 2957ms + 首次推理 8817ms 的暖机代价，对「重新识别框选
区域」这种单图交互是净亏。要换档得连这笔一起算。

## 2026-10-11：字幕 OCR 的 PP-OCRv6 det / rec / 漫画 CTC rec 上 DML 值不值

### 新参数（不给参数 = 旧行为、旧输出）

| 参数 | 作用 |
|---|---|
| `--shape x=1,3,H,W` | 覆盖输入形状；同名给多次 = 多个形状：每个先首跑一次，稳态按 S1,S2,S1,S2… 轮换 |
| `--block` | 多形状时稳态按块跑（S1×n 再 S2×n），区分「切换就重编译」与「只有某个形状快」 |
| `--threads N` | `IntraOpNumThreads`，DML/CPU 会话都设（app 不分 EP 一律传，Windows 上是 `min(核数,2)`） |
| `--runs N` | 稳态次数（多形状时为总次数） |
| `--session-per-shape` | 每个形状各建一个会话（分桶方案的暖机总价） |
| `--free-dim name=V` | `AddFreeDimensionOverrideByName`（同插件 `freeDimensionOverrides`） |
| `--dml-only` / `--cpu-only` | 只跑一边 |

CPU 会话对齐 `flutter_onnxruntime_plugin.cpp`：只设 intra-op 线程，图优化级别、
arena、执行模式全用 ORT 默认（`ORT_ENABLE_ALL`）。输入填常量 0.5，量的是纯推理，
不含 Dart 侧预处理/解码。

### 环境与形状

- ORT `Microsoft.ML.OnnxRuntime.DirectML` 1.22.0 + `Microsoft.AI.DirectML`
  1.15.4，SHA-256 与 CMakeLists 一致（`29F9…2E60` / `4E7C…15B9`）；MSVC 14.44（VS 2022 Community）。
- GPU：NVIDIA GeForce RTX 5090（DXGI adapter 0，驱动 32.0.15.9649 / 2026-05-05）；
  CPU：Ryzen 7 9800X3D 8C16T。**高端机，结论的方向可迁移，绝对值不可迁移。**
- 模型：`ppocrv6_small_det.onnx`、`ppocrv6_small_rec.onnx`（通用，按清单 revision
  `b8f84f0…` 下载）、`kellenok_manga_rec_v0.2.onnx`（逐列 CTC；CTC 模式下
  `ppRecPath == ctcRecPath`，横排行也用它）。三者输入都是 `x[-1,3,-1,-1]`，
  **自由维没有名字**，`freeDimensionOverrides` 钉不住。
- det 形状按 `ppDetInputSize`（短边 ≥64 不缩放，两边各取整到 32）：1300×180 的
  字幕块 → `[1,3,192,1312]`；另测 160×1344、224×1920。rec 形状按
  `ppRecPreprocess`：高 48、W = max(320, ceil(48·w/h))，测 320/640/960/1280。

### 单形状（每个会话只见一种形状；两轮中位数，单位 ms）

| 模型 / 输入 | DML 建会话 | DML 首跑 | DML 稳态 | CPU t2 稳态 | CPU t4 稳态 |
|---|---|---|---|---|---|
| det 192×1312 | 75–82 | 340–360 | 2.6–2.9 | 30–32 | 21–38 |
| det 160×1344 | 83–86 | 310–355 | 2.4–2.7 | 25 | 18–22 |
| det 224×1920 | 81–92 | 310–1090 | 3.3–8.7 | 52–67 | 42–48 |
| PP rec W320 | 118–128 | 384–889 | 2.4–3.6 | 7.4–7.5 | 4.9–5.8 |
| PP rec W640 | 103–136 | 327–540 | 2.9–5.9 | 13–16 | 9.8–16 |
| PP rec W960 | 108–137 | 327–619 | 3.7–3.9 | 20–24 | 13–18 |
| PP rec W1280 | 122–126 | 320–481 | 3.8–7.6 | 27–32 | 19–28 |
| CTC rec W320 | 147–292 | 342–710 | 2.4–6.7 | 6.4–8.6 | 5.0–7.6 |
| CTC rec W640 | 136–155 | 354–369 | 2.9–3.4 | 13–14 | 9.8–11 |
| CTC rec W960 | 152–266 | 346–426 | 3.5–3.6 | 19–22 | 14 |
| CTC rec W1280 | 130–153 | 334–363 | 4.2–4.8 | 27 | 16–18 |

CPU 建会话 40–146ms、首跑 ≈ 稳态，无暖机代价。三个模型 DML 都建得起来、无回退。

### 关键现象：一个 DML 会话只有它**见到的第一个形状**走快路径

| 场景（DML，threads=2） | 第一个形状 | 其后的形状 |
|---|---|---|
| 轮换 det 192×1312 / 160×1344 | 3.1 | 22.4 |
| 轮换 rec 640 / 960 | 3.8 | 28.8（CPU t2 同形状 20.1） |
| 轮换 CTC 640 / 960 | 3.6 | 26.4（CPU t2 20.5） |
| 按块 rec 640×30 → 960×30 | 4.1 | 37.5 |
| 按块 CTC 960×30 → 640×30 | 6.2 | 47.8（CPU t2 ≈ 13） |
| 扫 21 种 rec/CTC 宽（320..1280 步 48） | 3.6 | 每种 24–36，与宽度无关 |
| 扫 18 种 det 形状（H 160/192/224 × W 1248..1408） | 3.1 | 每种 22–36 |

按块跑把同一个第二形状连跑 30 次也降不下来 ⇒ 不是「切换时重编译一次」，而是第一个
形状之后的所有形状**永久**落到一条约 25–35ms 的平坦慢路径上（与输入大小几乎无关，
是调度开销而非算力），对 rec/CTC 来说**比 CPU 2 线程还慢**。

分桶验证（`--session-per-shape`，同一进程每桶一个会话）：每个会话的形状都回到
3.4–5.3ms（det 两桶 5.8–6.0ms），暖机总价 rec 4 桶 3.3s、CTC 4 桶 4.3s、det 2 桶 1.6s
（这一批机器负载偏高，首跑 380–1000ms，比单形状表里的 320–360ms 慢）。

### 结论

1. **按现在的接法（每个模型一个会话、形状随字幕块变）不要开 DML**：只有第一次见到
   的形状快，其余每次 25–35ms，rec/CTC 比 CPU t2 慢，det 与 CPU t2 打平；还白付
   每会话 ~0.1s 建会话 + ~0.3–1s 首跑。`ocr_inference.dart` 的「Windows 不要 DML」
   对这三个模型在当前接法下仍成立。
2. **DML 只在「一个会话只见一种形状」时划算**：右侧补零把 rec/CTC 的 W 取整到桶
   （如 320/640/960/1280，超出再加桶或切段），每桶一个 DML 会话；det 同理固定画布
   （如 192×1344、224×1920）。稳态 rec/CTC 每行省 ~4–25ms、det 每块省 ~25–60ms，
   换来每桶 ~0.4–1s 暖机和显存占用。只值得用于整轨字幕抽取这类成百上千次调用的
   批任务；单帧/少量交互仍应走 CPU。rec/CTC 本来就是右侧补零到 ≥320，补到桶是同一
   契约的延伸，但 CTC 尾部多出的空白帧、det 补边后的 DB 概率图都要另做准确率对拍，
   本探针不测准确率。
3. 留在 CPU 时，threads=4 对大形状比 2 快 1.2–1.7×（det 224×1920 52→42ms、CTC W1280
   27→16ms），小形状无差别；是否放宽 `planOcrAcceleration` 的 2 线程上限另议（那条
   上限针对的是多个会话串行时的超订）。

复现（`run/` 下放好三个 DLL 后）：

```bash
probe.exe ppocrv6_small_det.onnx --shape x=1,3,192,1312 --threads 2 --runs 30 --dml-only
probe.exe kellenok_manga_rec_v0.2.onnx --shape x=1,3,48,640 --shape x=1,3,48,960 --threads 2 --runs 40 --dml-only
probe.exe kellenok_manga_rec_v0.2.onnx --shape x=1,3,48,960 --shape x=1,3,48,640 --block --threads 2 --runs 60 --dml-only
probe.exe kellenok_manga_rec_v0.2.onnx --shape x=1,3,48,320 --shape x=1,3,48,640 --shape x=1,3,48,960 --shape x=1,3,48,1280 --session-per-shape --threads 2 --runs 20 --dml-only
```
