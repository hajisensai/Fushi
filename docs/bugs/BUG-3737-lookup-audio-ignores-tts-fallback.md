## BUG-3737 · 查词 ♪ 不走已配置的 TTS 兜底，制卡却走
- **报告**：2026-10-23（用户反馈：「Windows平台，模型里配置了TTS，但查词时还是没有用它发音……sovits配置试听这里朗读没问题」；截图：制卡发音兜底 = GPT-SoVITS（本机），查词页 ♪ 提示「暂无发音」）
- **真实性**：✅ 真 bug（行为不一致）。根因 `fushi/lib/src/utils/misc/lookup_audio_playback.dart` `resolveLookupAudioUrl`：只跑 `resolveConfigured`（已启用音频源），注释写明「no TTS fallback」；TTS 兜底只接在制卡链 `fushi/lib/src/creator/enhancements/local_audio_enhancement.dart` 第 3 步。同一个词点 + 制出的卡带 TTS 发音，♪ 却说「暂无发音」。
- **[x] ① 已修复** — `resolveLookupAudioUrl` 在所有音频源落空后用 `lookupTtsFallbackVoiceOf`（用户**显式**选过的兜底声音；没碰过设置 / 选了「不使用」不兜底，保持旧行为）合成；「选择音频源」菜单无候选时同样给出 TTS 一项。制卡链第 2 步传 `ttsFallback: false`，避免一个词合成两次。用户 2026-10-23 拍板：「配置了tts就要兜底」。
- **[x] ② 已加自动化测试** — `fushi/test/creator/mining_tts_fallback_test.dart`「查词兜底只认显式选过的声音」。
- **备注**：查词 ♪ 是解析即播，GPT-SoVITS 首次合成要等服务出声（同词同音色走 `TtsAudioCache` 不重复合成）。合成失败只记错误日志（设置 › 诊断），♪ 仍提示「暂无发音」。
