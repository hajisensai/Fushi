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
