## BUG-2888 · KiriKiri 掐断用的静音语音被配给下一句旁白
- **报告**：2026-10-03（agent 在 ceshi 样本 Fate/stay night[Realta Nua]（KiriKiri2 2.31 / BCB）真机验收 BUG-2887 时发现：旁白「闇を弾く声で、彼女は言った。」配对 `matched/game_resource`，落盘的语音是 `mute.wav`）
- **真实性**：✅ 真 bug。KAG 脚本惯用「播一段极短静音语音」来掐断上一条语音：Fate 的 `mute.wav` 0.108 s、8-bit、样本全在零点 ±2。`native/galgame_hook/hook/adapters/kirikiri_adapter.inc` 的 `WriteKirikiriVoiceResource`（:177）只按容器魔数认音频，这段静音照样落盘、照样作为「最近一条引擎语音」配给紧跟其后的旁白——宿主报引擎资源命中，卡片拿到一段听不见的 0.1 秒，比降级 loopback 更糟（看起来是成功）。判据只能按内容：按名字（`mute`）认是单游戏特判，违反引擎级适配规则。
- **[x] ① 已修复** — 新增纯头 `native/galgame_hook/include/pcm_wav_silence.h`：解析 RIFF/WAVE（PCM / IEEE float / EXTENSIBLE，块按偶数对齐、data 按实际字节截断到整帧），取整段峰值折算到 16-bit 标度（复用 `voice_clip_energy.h` 的 `ClipSampleAbs16Scale`），低于 1024（≈ -30 dBFS）即静音。用峰值不用均值：真人声句子大段停顿会拉低均值。解析不了的载荷（压缩 fmt、块残缺）一律判「不是静音」，只做减法不误杀。`WriteKirikiriVoiceResource` 对直落的 WAV（:182）与 TCWF 解码产物（:192）都先过这道门，静音不落盘、不进配对。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/pcm_wav_silence_test.cpp`：真机 mute.wav 形状（8-bit ±2）、8-bit 单点有声、16-bit 阈值两侧（1023 静 / 1024 有声）、长静音里一处发声不判静音、立体声、float、EXTENSIBLE、fmt 前奇数长度块、data 声明超长截断到整帧、ADPCM / 12-bit / 空 data / Ogg / data 先于 fmt 全部判「不是静音」。变异实测：改坏静音判据后测试变红。x86 / x64 CTest 均过。
- **备注**：
