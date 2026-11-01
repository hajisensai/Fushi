# TTS 接入：引擎层 → 阅读器朗读高亮 → 有声书制作台

> 状态：计划（2026-10-11 用户确认方向）。分阶段在 `claude/tts-pipeline` 及后续分支实施，每期独立审查后合并。

## 目标与非目标

- 目标：EPUB 正文由 TTS 朗读并同步高亮（句级必有，引擎给时间边界时到词级）；最终提供有声书制作台，整书生成音频、与 ASR 转录联动质检，产物作为普通有声书入库并可导出。
- 主力引擎 GPT-SoVITS（用户自建服务）；同时内置在线第三方（微软、谷歌）与系统 TTS 离线兜底。
- 非目标：跟读/影子练习（录音对比、逐句停顿）——用户明确砍掉；卡片复习朗读不在本计划内。

## 与 `codex/audiobook-tts-current` 的关系

该分支（`f2da3e686b`、`e450b51064`，基线 2026-10-07）**不合并、不移植代码与 UI**：与 GPT-SoVITS 写死、单预设、只认 WAV；渐进队列约 600 行状态机塞进 `AudiobookPlayerController` 并波及录音有声书路径；混入格式重排与 Windows Dev runner；UI 不合格。

只作为**经验参考**，需要在新实现中覆盖的已知坑：

- 试听在 `play()` 返回后立即释放播放器，media_kit 下被截断（BUG-3072）。
- 跳句等整批预取完成后跳回旧句（BUG-3073）。
- 缓存键包含 endpoint/apiKey 导致无谓失效；缓存实例非单例导致 pin 不共享。
- 整书分句在 UI 线程同步执行，大书卡顿。
- 长句不切分，首句延迟高（实测 4070 Ti 上 GPT-SoVITS v5 实时率约 1.2，持续 1× 播放会等待）。
- 媒体通知仍声明可 seek，而生成中整书时间轴未知。
- 原地修改共享 `AudioCue.audioFileIndex`。

## 引擎分类

| 引擎 | 类型 | 时间粒度 | 凭据 | 备注 |
|---|---|---|---|---|
| GPT-SoVITS `api_v2` `POST /tts` | 自建（本机/局域网/服务器） | 句（按每句音频时长） | 可选网关 Bearer | 逐句请求 `text_split_method=cut0`；`ref_audio_path` 是服务端路径；模型由服务端预加载，客户端不切权重 |
| 微软 Edge 朗读 | 在线，免费免配置 | 词（WordBoundary） | 无 | 非官方接口（需 Sec-MS-GEC 令牌与版本号跟进），可能失效或限流；首次启用明示「非官方在线服务」；不用于整书批量生成 |
| 微软 Azure Speech | 在线，官方 | 词（websocket WordBoundary / Batch 边界文件） | 用户 key + region | 与 Edge 共用 websocket 协议实现，仅鉴权不同 |
| Google Cloud TTS | 在线，官方 | Neural2/WaveNet 经 SSML `<mark>` 到词；Chirp3 HD 仅句 | 用户 API key | Google 翻译 `translate_tts` 不内置（音质差、长度限制、违反条款） |
| 系统 TTS | 离线 | 句 | 无 | 复用 `TtsChannel.ttsToFile` / `desktop_tts.dart`；iOS 当前无实现，macOS `say` 需改出 WAV |
| 后续：OpenAI 兼容 `/v1/audio/speech`、VOICEVOX/AivisSpeech | 自建 | 句；VOICEVOX 可到音拍 | 视服务 | 不在首批 |

在线引擎会把正文发给第三方，设置页按引擎标注「在线」与隐私提示。

## 阶段 0：引擎层（无 UI）

位置：`packages/fushi_engine/lib/tts/`（纯 Dart，遵守引擎纯度守卫），app 与无头服务端共用，便于阶段 2 把整书生成派给装了 GPT-SoVITS 的机器。出站 HTTP 必须经宿主注入的 client（全应用代理装配）；系统 TTS 通过 app 侧注入的 provider 实现。

```dart
abstract class TtsProvider {
  String get id;
  TtsCapabilities get capabilities; // timing: none/sentence/word/mora；online；needsCredential；formats
  Future<List<TtsVoice>> listVoices({String? locale});
  Future<TtsResult> synthesize(TtsRequest request, {required TtsCancelToken cancel});
}

class TtsResult {
  final String audioPath;
  final TtsAudioFormat format;
  final int durationMs;
  final List<TtsBoundary> boundaries; // 相对本段起点，按合成文本 UTF-16 偏移
}
```

- **声音预设** `TtsVoicePreset`：多个，`id / providerId / displayName / params / revision`；每语言一个默认。
- **凭据**与预设分开存，偏好键名含 `api_key`，被 `pref_redaction_policy.dart` 拦截，不进同步/备份/Profile 分享；日志与提示不含原始响应正文与密钥。
- **缓存**：应用级单例；键 = `providerId + 影响音色的 params + revision + 合成文本`，不含 endpoint/凭据；存引擎原生格式 + `meta.json`（时长、边界）；原子发布、校验、pin 引用计数、LRU 上限。
- **文本**：分句、ruby 读音入合成/原文用于显示、原文 UTF-16 / 归一化匹配 / 阅读进度三套坐标；后台 isolate 计算并按书缓存；首句短切以降低首响。
- **测试**：每个 provider 用本地假服务器做契约测试（成功、错误码、取消、超时、脱敏、边界换算）。

## 阶段 1：阅读器朗读 + 高亮

- 合成句 → `AudioCue`，复用有声书的正文高亮、跨章跟随、歌词模式、制卡句子音频。
- 词级：`TtsBoundary` → `CueTokenTiming`（与 ASR token 高亮同一路径）。
- 渐进播放做成**独立的 source 适配层**，录音有声书路径不改行为。
- 入口：已有有声书时听书按钮 / 快捷键 B 行为不变；无有声书时提供「TTS 朗读 / 导入有声书」。
- 生成中不暴露整书时长、通知不声明 seek；暂停后新片段到达不自动恢复；切书/停止取消请求。
- UI 按现有 MD3 设置组件实现（引擎列表形态参考 `ai_provider_settings_section.dart`），设置项进 settings schema。
- 验收：翻页 / 滚动 / VN 三种模式；Windows 上 GPT-SoVITS 与 Edge 真实端到端。其余平台未上真机前标 `implemented_unverified`。

## 阶段 2：有声书制作台

- 任务队列参照 `AudiobookTranscribeImportQueue`（JSON 清单、串行、重启续跑）；新增 host job `kind='tts_render'`，可在互联 host / `fushi_server` 上执行。
- 页面：选书 → 章节 → 预设；字数与云服务额度预估；按章生成进度；逐句试听、发音词典改读音、单句重生成。任务区块挂进现有任务页。
- **ASR 联动质检**：生成后用现有 ASR 转写并与原文比对，标出漏读/重复/读错句，一键重生成；引擎无词级边界时用 ASR token 时间补词级高亮。
- 入库：逐句生成即有精确时间，直接写 SRT + cues，经 `syncAudioFiles` / `replaceAlignment` / `saveCues` / `writeEpubBackedSrtBook` 绑定到该 EPUB，无需再跑匹配。
- 导出：m4b（AAC，concat 解复用 + aac + `-f mp4`）。章节需给 `tool/ffmpeg-min` 增加 `ffmetadata` 解复用与 `ipod` 复用（或 Dart 写章节 atom）；mp3 / `.opus` 需另增编码器/复用器，暂不做。

## PR 拆分

1. 引擎接口 + GPT-SoVITS + 系统 TTS + 缓存 + 预设/凭据存储（纯引擎，带契约测试）。
2. Edge / Azure / Google provider + 设置页（多预设、试听）。
3. 渐进 source 适配层 + 阅读器朗读与句级高亮。
4. 词级高亮（边界 → `tokenTiming`）。
5. 制作台：任务队列、host job、按章生成、入库。
6. ASR 质检、单句重生成、发音词典。
7. ffmpeg-min 章节组件 + m4b 导出。

## 本机一键部署 GPT-SoVITS（2026-10-14）

用户反馈「下模型、部署全在 app 外，太难用」。Windows 上改为 app 内完成：

- 引擎层 `packages/fushi_engine/lib/tts/local/`：
  - `GptSovitsInstaller`：从 HF 官方 / ModelScope 镜像清单取最新整合包 → `ResumableDownloader` 断点续传 + sha256 → 系统 `System32\tar.exe`（libarchive + liblzma）解 7z → 按内容找 `runtime/python.exe` + `api_v2.py` → 写 app 自己的 `fushi_tts_infer.yaml` 副本（api_v2 会回写 `-c` 指定的配置）→ 删包。
  - `GptSovitsLocalServer`：经 `HelperProcessRegistry` 起 `runtime\python.exe -I api_v2.py -a 127.0.0.1 -p <port> -c <副本>`，`GET /openapi.json` 探活，端口上已有服务则借用，保留 200 行日志尾。
  - `GptSovitsLocalEngine`：偏好 `tts_gpt_sovits_local`（设备本地）。RTX 50 系按 `nvidia-smi` 选 nvidia50x0 包；没有 N 卡用普通包，api_v2 自动降到 CPU。
- 自动拉起：`TtsServices` 注册表里 GPT-SoVITS 换成 `AutoStartGptSovitsTtsDescriptor`（id / 参数 / 缓存键不变），指向托管端口的声音合成前先确保服务就绪；退出链停服务（Windows 不连坐子进程）。
- UI：「本机 GPT-SoVITS」页（下载源 / 版本 / 安装位置 / 进度与取消 / 使用已解压的整合包 / 启停 / 日志 / 用本机服务新建声音 / 删除）。入口：添加声音对话框首项、GPT-SoVITS 声音编辑页、「设置 › 模型 › 语音合成」与「模型 › 模型文件」。
- 设置整合：「模型 › 语音合成」从只写着系统引擎的说明页改为 TTS 的唯一主页（朗读声音 + 本机 GPT-SoVITS 状态 + 制卡兜底）；「模型文件」分区把 GPT-SoVITS 整合包与 OCR 模型并列；「阅读 › 有声书 › 朗读声音」保留为同一页的快捷入口。
- 易用性：本机服务时参考音频可直接选文件（复制进 `<support>/tts_reference_audio/`，文件名含假名 / 汉字时预填参考文本）；语言代码显示可读名。
- 未做：macOS / Linux（官方无免安装包，仍按外部服务手填地址）；切换自训练权重（`/set_*_weights`）。真实整合包（约 11 GB）的下载 → 解压 → 合成未在真机端到端跑过，状态 `implemented_unverified`。

## 本机一键部署官方 Irodori-TTS-Server（2026-10-16）

所有者拍板：按官方来——部署 `Aratako/Irodori-TTS-Server`（OpenAI 兼容），不动所有者自己的有声书工作台接入（`IrodoriTtsDescriptor`，`/api/quick/*`、端口 7870，行为不变、两者并存）。

上游事实（读 Irodori-TTS-Server main `61012c7` 与 Irodori-TTS `89f9d8f` 核实）：

- 官方装法 `uv sync --extra cu128|rocm|cpu`（三者互斥；**没有 xpu**，xpu 只在 Irodori-TTS 训练仓里）+ `uv run --no-sync python -m irodori_openai_tts --host --port`；Python ≥3.10（`.python-version` = 3.10），`torch>=2.10,<2.11`。cpu extra 在 macOS 落到 PyPI 的 torch，`IRODORI_MODEL_DEVICE=auto` 时自己用 MPS。
- 接口：`GET /health`（不加载模型）、`GET /v1/models`（`owned_by: irodori-tts`）、`GET/POST /v1/audio/voices`（multipart `file` + `voice_id`，id 只能 `[A-Za-z0-9_-]`）、`GET/PUT/DELETE /v1/audio/voices/{id}`、`POST /v1/audio/speech`（`model` 必须等于 `IRODORI_MODEL_NAME`，默认 `irodori-tts`）。内置声音 `none`（不用参考音频；配 `irodori.caption` 即 Voice Design）。
- 服务默认 checkpoint 是 `Aratako/Irodori-TTS-v4-Small`；本实现按所有者要求默认 **v4.1-Small**（Irodori-TTS 主仓 README 的默认，同一代码路径），另给 **v4.1-Small-MF**（MeanFlow，4 步，CPU 上快得多）可选。编解码器 `Aratako/Semantic-DACVAE-Japanese-32dim`。三个模型仓库均 MIT、非 gated。
- 依赖里有三个 git 依赖（`irodori-tts`、`dacvae`、`silentcipher`）。**uv 取 git 依赖必须调用系统 git**（实测无 git 时报 `Git executable not found`）；重新 `uv lock` 指向本地路径也不可行（要为 rocm 等全部平台取元数据，实测在 rocm torch 轮子上内存映射失败）。
- 首次启动时水印模型 `silentcipher.get_model` 会 `snapshot_download("sony/silentcipher")`（约 70 MB，经 `HF_ENDPOINT`），失败只告警、不挡合成。

部署设计（`packages/fushi_engine/lib/tts/local/irodori_local_*.dart`）：

- 专属目录 `<安装目录>/fushi-irodori-tts/`：`uv/`（官方单文件 uv 0.12.21，四个平台包钉 sha256）、`python/`（`UV_PYTHON_INSTALL_DIR`，`uv python install 3.10 --no-bin --no-registry`：不写 PATH、不写注册表、不碰系统 Python）、`cache/`（`UV_CACHE_DIR`）、`src/{server,irodori-tts,dacvae,silentcipher}`（GitHub 源码 zip，commit 与 `uv.lock` 一致，sha256 校验）、`src/server/.venv`、`models/`、`voices/`（`IRODORI_VOICES_DIR`）、`hf/`（`HF_HOME`）。删除 = 整目录删掉。
- 不经 git 的依赖安装：`uv export --frozen --extra <后端> --no-emit-project --emit-index-url` 导出官方锁定清单（带哈希）→ 三行 git 依赖换成 `file:///` 本地目录（缺一行或多出别的 git 依赖都拒绝安装）、只留所选后端的 PyTorch 索引（macOS 一个不留）、末尾加服务本体 → `uv venv --managed-python --clear` → `uv pip sync --index-strategy unsafe-best-match`（每个包都带锁文件哈希，从哪个索引取都必须是那个文件）。版本与哈希全部来自官方锁文件。
- 安装命令不继承父进程的 `UV_*` / `VIRTUAL_ENV` / `PYTHONPATH` / `CONDA*` / `PIP_*INDEX*`；app 的代理经本机中继（`appNativeProxyEnvironment`）给 uv。
- 模型由 app 下载（`ResumableDownloader`：断点续传、进度、sha256；钉 revision），可选 Hugging Face / hf-mirror.com（实测从境外出口访问 hf-mirror 会 308 回 huggingface.co）。服务用 `IRODORI_CHECKPOINT` / `IRODORI_CODEC_REPO` 本地路径加载，不在服务里下大文件。
- 每步可重入：uv 版本对、源码 commit 对、环境指纹（uv / Python / 各 commit）与后端对、模型文件齐 → 跳过。换模型只补下模型，换后端只重装环境。
- 进程托管：GPT-SoVITS 的托管逻辑抽成共用 `LocalServiceProcess`（`local_service_process.dart`，GPT-SoVITS 改为子类，行为与测试不变）。Irodori 起 `.venv` 里的 python `-m irodori_openai_tts --host 127.0.0.1 --port <port>`（等价于官方 `uv run --no-sync`；Windows 上 venv 的 `python.exe` 是启动器，杀它连坐子进程——实测）；`IRODORI_PRELOAD=true` 让模型读完才开端口，探活 `GET /health` + `GET /v1/models`（`owned_by == irodori-tts` 才算），就绪超时 10 分钟；pid 文件 `.fushi_irodori.pid` 认领崩溃残留；`PYTHONUTF8=1` / `PYTHONIOENCODING=utf-8`。默认端口 8088，可改，不许 7870 / 7871 / 9880。
- provider `irodori_server`（`irodori_server_tts_provider.dart`）：`/v1/audio/voices` 列声音，`/v1/audio/speech` 合成（`response_format: wav`，可选 `irodori.caption`、Bearer 密钥），并发 1；声音管理 `IrodoriServerVoiceApi`（上传 / 删除）。注册表里换成 `AutoStartIrodoriServerTtsDescriptor`（指向托管端口时朗读前自动拉起）。
- UI：「本机 Irodori-TTS」页（显卡 / 后端 / 模型 / 端口 / 下载源 / 位置 / 进度与取消 / 安装日志 / 启停 / 服务日志 / 服务上的声音：上传参考音频、删除 / 用本机服务新建声音 / 删除）；入口：添加声音对话框、Irodori 声音编辑页、「模型 › 语音合成」「模型 › 模型文件」。桌面三端显示，移动端不显示。CLI：`fushi_cli models download|status|cancel|rm|start|stop irodori`（`--backend` / `--model` / `--source hf|hf-mirror` / `--dir`）。

验证状态（2026-10-17）：

- 引擎单测 68 条全绿（安装状态机 / 清单改写 / 探活判据 / provider 请求格式 / 上传 multipart / 设置 / 删除只删专属目录；GPT-SoVITS 原有测试照常通过）。
- Windows 真机（RTX 4070 Ti，cu128）：用引擎层真实代码走 安装（uv → 源码 → Python 3.10 → `uv pip sync` → 模型，无 git，约 62 分钟，主要是 3 GB 模型下载）→ 启动（首次 75 s，其后 38 s）→ 列声音 → `none` 合成（4.6 s 音频，约 4.3 s）→ 上传参考音频 → 用它合成 → 删声音 → 停止（端口释放）全部通过；装好的目录约 8.6 GB。发现并修掉：停止后端口晚一拍才关（venv 启动器连坐子进程），`stop` 现在等端口释放。
- macOS 27.2（Apple 芯片，cpu extra）：uv / Python / 锁定依赖 / 模型下载（经系统代理）/ 删除都通过；**服务启动失败**：官方锁文件钉的 `scipy==1.15.3`（Python 3.10 能用的最后一版）的 `_spropack` 扩展在 macOS 27 的 dyld 下加载失败（`__DATA/__thread_bss has a zero-fill section type, but offset field is not zero`），`irodori_tts` 导入 transformers 时连带失败。这是上游锁文件 × 新 macOS 的不兼容，要修只能偏离官方锁（换 Python 3.11+ 并升级 scipy，需重新解析依赖），待所有者拍板；app 内表现为「服务启动时退出了，请查看日志」。
- Linux：只做了静态分析（引擎是纯 Dart，Linux 分支由单测的非 Windows 路径覆盖），未真机安装。
- 部署页 UI 只过了 `flutter analyze`，未在真 app 里人工过一遍。

## 实时朗读多声优 + 提前生成（2026-11-01）

- **多声优**：书在制作台标过说话人、给角色配过声音（选角表 `TtsCast`）时，阅读器实时朗读按句换声音。句子先归「声音槽」（`tts_read_along_voices.dart`）：配了声音的角色各一个槽，其余（旁白、没配声音的角色、没标注的句子）归默认槽，用当前朗读声音；同一份预设只建一个引擎实例、共用一个并发上限。
- 分句与制作台同口径（`kStudioSentenceMaxLength` = 120），选角表的句首坐标才对得上；并句（`mergeShortTtsSentences`）只在同一声音槽内进行。槽按角色分而不按预设 id 分：播放中换默认声音不会把并在一起的句子读串，角色台词的缓存键不变、直接命中。
- 角色声音被删 / 引擎不可用 / 配置不完整 → 起会话失败（`TtsStartProblem.castVoiceUnavailable`），提示并打开制作台；不悄悄换成默认声音。
- 调度器（`TtsSynthesisScheduler.voices`）：每句指定声音，缓存键按该声音的音色身份算，并发按声音分别计（`TtsSchedulerVoice.concurrency`，取 `ttsEffectiveConcurrency`）。
- **提前生成**：预取窗口取「60 秒 × 倍速」与「当前章剩余 + 下一章」（`ttsPrerenderEnd`）中的大者，上限 1500 句。付费云引擎（Azure / Google）同样会提前生成到下一章末，暂无开关。

### 微软 Edge 实测（2026-11-01，本机网络，`packages/fushi_engine/tool/bench/tts_multivoice_bench.dart`）

素材：《やはり俺の青春ラブコメはまちがっている。》正文前 120 句 / 3276 字；旁白 Nanami（90 句）+ 台词 Keita（30 句）；每轮全新冷缓存。

| 每声音并发 | 总在途 | 耗时 s | 音频 s | 吞吐（×实时） | 单句延迟 p50 / p90 ms | 单次请求失败（均被重试救回） |
|---|---|---|---|---|---|---|
| 1 | 2 | 77.0 | 652.7 | 8.48 | 782 / 1055 | 0 |
| 2（默认） | 4 | 40.3 | 652.7 | 16.19 | 813 / 1068 | 1 |
| 3 | 6 | 27.5 | 652.7 | 23.71 | 793 / 1093 | 6 |

倍速播放模拟（每声音并发 2，播放器按真实音频时长 ÷ 倍速消费 120 句）：2× / 3× / 4× 下「提前生成」与旧「60 秒窗口」**卡顿均为 0**，首句等待 0.8～1.0 s。Edge 吞吐远大于消耗，两种预取在这里没有差别；提前生成的收益在网络抖动 / 慢引擎时才显出来，未实测。

结论与限制：

- Edge 多声优 4× 倍速可行；并发 3 起单次失败明显增多（限流前兆），默认保持 2。
- **Edge 免费接口的日语声音只有 Nanami、Keita 可用**（`tts_edge_voice_probe.dart` 实测：Aoi / Daichi / Mayu / Naoki 连接即被关闭 `closed early`，随后 429）。Edge provider 的 SSML 把 pitch / rate 写死为 +0，要用同一底子派生更多角色需另开参数。
- 只做了引擎层真实网络实测（真实 Edge + 真实调度器 + 模拟播放器）；未在真 app 里用带选角表的书端到端朗读。

### OpenAI 兼容语音接口 + VPTTS 实测（2026-11-01）

- 新引擎 `openai_compatible`（`openai_compatible_tts_provider.dart`）：`POST /v1/audio/speech`（wav、服务端倍速 1.0）、`GET /v1/audio/voices` 列音色（显示「名字（id）」）。model 留空时探一次 `GET /v1/models`，只有一个模型就用它，否则 / 没有该接口用 `tts-1`；缓存身份带 host + port，不带密钥。默认地址 `http://127.0.0.1:8000`、并发 1。
- 起因：本机 VPTTS 0.5.0（VOICEPEAK 声库的 OpenAI 兼容服务，42 个音色）只认 `model: voicepeak`；现有 Irodori-TTS-Server 引擎写死 `irodori-tts`，被拒 400 `unknown_model`。

素材同上，前 40 句 / 1041 字；旁白「女性1」，台词在「男性1」「東北イタコ」间轮流；每轮冷缓存，本机 CPU 推理。

| VPTTS 驻留上限 | 声音数 | 每声音并发 | 吞吐（×实时） | 单句延迟 p50 / p90 s | 2× 卡顿 | 3× 卡顿 |
|---|---|---|---|---|---|---|
| 2（默认） | 3 | 1 | 1.37 | 4.1 / 17.7 | 8 次 / 57 s | 13 次 / 73 s |
| 4 | 3 | 1 | 2.22 | 3.7 / 7.2 | 1 次 / 3 s | 10 次 / 14 s |
| 4 | 3 | 2 | 2.55 | 7.2 / 12.0 | — | — |
| 4 | 2 | 1 | 2.65 | 2.8 / 4.7 | 0 | 5 次 / 9 s |
| 4 | 2 | 2 | 2.63 | 5.9 / 7.9 | — | — |

- 声音数超过 VPTTS 驻留上限（`vptts.toml` `[backends.voicebank] max_resident_voices`，按需模式 1–8，默认 2）时每次换声音要重新加载（十几秒）。驻留数应 ≥ 一本书实际用到的声音数；每个驻留音色约 540 MB 内存。
- VPTTS 整体吞吐约 2.6× 实时封顶（CPU 吃满），每声音并发 2 不增吞吐、只加延迟，默认并发 1 合适。实时朗读 2× 可用，3× 会卡；更高倍速走制作台离线生成。
- 首句等待 3.5～4.8 s。提前生成与 60 秒窗口在这里同样没有差别（吞吐不超过 3× 消耗，缓冲攒不起来）。
