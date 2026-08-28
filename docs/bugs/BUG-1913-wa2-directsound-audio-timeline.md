## BUG-1913 · WA2 DirectSound 制卡炸音且未取得 VOICE.PAK 源语音
- **报告**：2026-08-28（用户）
- **真实性**：✅ 真 bug。WA2 的 DirectSound `Unlock` 链只提供引擎解码后的循环缓冲写入，不能作为逐句源文件；新增的 `VOICE.PAK` 读取门又把真实 `ReadFile` 返回 VA `0x00459142` 错写成 RVA `0x058142`（应为 `0x059142`），导致资源 observer 永远在 `hook/adapters/leaf_aquaplus_adapter.inc` 的 caller 身份门提前返回。
- **[x] ① 已修复** — 复用共享 KernelBase 文件 API broker，按精确 WA2 可执行文件身份验证 `VOICE.PAK` / `IC\\VOICE.PAK` 的 LAC 索引；播放读取命中精确 entry 起点后，由 worker 重新打开已验证归档并逐字节发布完整 Ogg。修正返回 RVA 为 `0x059142`，制卡不再依赖会炸音的 DirectSound PCM。
- **[x] ② 已加自动化测试** — `tests/leaf_aquaplus_voice_archive_test.cpp` 覆盖 LAC 边界、索引、entry 查找与完整 Ogg EOS；`tests/leaf_aquaplus_adapter_test.cpp` 固定 `0x00400000 + 0x059142 == 0x00459142`；`tests/resource_audio_ready_test.cpp` 固定资源音频就绪能力。
- **备注**：2026-08-28 用户在原始 WA2 路径确认验证通过并完成真实制卡；验证音频来自 `VOICE.PAK` 源 Ogg。`IC\\VOICE.PAK` 使用同一已验证解析器，但本次接受会话未单独覆盖 IC 剧情。
