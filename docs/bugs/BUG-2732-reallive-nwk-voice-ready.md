## BUG-2732 · RealLive NWK 语音已导出却被 DirectSound 流（BGM）冒领配对
- **报告**：2026-09-27（P1 真机验收自查，智代アフター 2005 日文原版 RealLive.exe SHA-256 `0075C027…364F9A`）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/adapters/reallive_adapter.inc` 的 NWK 导出路径（`ProcessRealliveNwkTask` → `WriteVoiceOggAt`）只置 adapter 私有位，从不写共享头；宿主 `HasReadyGameResourceAudio`（`include/voice_hook_ipc.h`）看不到任何就绪位，`raw_voice_ready` 恒 false，会话落 `enginePcm`，每句（含旁白、主人公无声台词）都配到同一 DirectSound 流缓冲的 530ms 切片，最长一句 18.7s。accept4 的 audio 判据只看「非 loopback」，把它误判 PASS。
- **[x] ① 已修复** — `597258b4603`：身份门（`g_reallive_capture_armed`）打开后真登记到 `.nwk` 句柄时置 `kDiagVisualArtsOvkHooksReady`（与 Siglus OVK 同一「VisualArts 语音归档已打开」语义；只置 HooksReady、不置 Captured，因 NWA 解码 WAV 与源条目非同字节）。真机复验：`hookdiag=0x00041c01`，会话切 `gameResource`，智代台词 `matched/game_resource`（`Z0629.nwk_<id>.wav`），旁白 / 主人公行保持 pending。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/adapter_structure_test.py::test_reallive_nwk_publishes_visual_arts_voice_ready_only_when_armed`。
- **备注**：遗留 ① accept4 audio 判据对 engine_pcm 流式切片无辨别力（另行处理）；② RealLive 的 Luna 线程 key 跨启动不稳定，记住的选择落到名字线程。
