## BUG-4503 · VOICEVOX 0.26 风格列表为空，选不了说话人
- **报告**：2026-11-15（用户：应用内反馈 odiVNK86Qv，Windows）
- **真实性**：✅ 真 bug。VOICEVOX engine 0.25+ 的 `/speakers` 给支持流式合成的风格报 `type: "streaming_talk"`（0.26 起默认角色全是它；引擎 `voicevox_engine/metas/metas.py` 的 `StyleType` 已含此值，`metas_store._TALK_STYLE_TYPES = ["talk", "streaming_talk"]`，且注明它同样支持 `/audio_query` + `/synthesis`）。`packages/fushi_engine/lib/tts/providers/voicevox_tts_provider.dart:285`（修前）`parseVoicevoxSpeakers` 只收 `type == null || type == 'talk'`，把所有 `streaming_talk` 风格丢掉 → 列表为空 → 必填说话人选不了。反馈截图里引擎返回的 `{"name":"ノーマル","id":3,"type":"streaming_talk"}` 与此一致；手填 speaker=3 校验通过，说明合成路径本身没问题。
- **[x] ① 已修复** — `voicevox_tts_provider.dart` 新增 `voicevoxTalkStyleTypes = {'talk', 'streaming_talk'}`（与引擎 talk 系集合一致），`parseVoicevoxSpeakers` 按该集合过滤；歌唱（`singing_teacher` / `frame_decode` / `sing`）与 `humming` 照旧排除。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/tts/voicevox_tts_provider_test.dart`：`parseVoicevoxSpeakers keeps streaming_talk styles (engine 0.26+)`；原用例 fixture 补 `singing_teacher` / `frame_decode`，确认仍被排除。
- **备注**：未在真 VOICEVOX 0.26 上复测（本机无引擎）；修法只放宽到引擎自己声明为 talk 系的类型。
