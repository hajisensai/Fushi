## BUG-2194 · 扩展 YouTube 轨枚举被 12 条上限截掉原语言英语轨
- **报告**：2026-09-06（用户截图：Fushi 侧栏字幕列表里俄/孟/德/旁遮普/日/法/波/荷/葡/阿/韩/马拉雅拉姆 12 条齐全，唯独没有英语；YouTube 原生菜单里有「英语（自动生成）」；「而且还缺少英语」）
- **真实性**：✅ 真 bug。`tools/browser-extension/youtube-bridge.js` `fetchAndPublish` 为了不把整集轨 × N 全拉下来，按 YouTube 给的原始顺序只取前 **12** 条 `captionTracks`。自动配音视频每种配音语言各带一条 ASR 轨（几十条），原语言（用户正在听的音轨、也就是学习语言）排在后面就被截掉——用户列表正好 12 条、无英语。
- **[x] ① 已修复** — 上限之前先 `prioritizeCaptionTracks(tracks, getAudioTrack())` 排优先级：当前音轨默认字幕轨（`defaultCaptionTrackIndex` / `isDefault`）→ 语言码与当前音轨语言一致 → 人工轨（非 asr）→ 其余按原顺序；上限提到 20（`MAX_TRACKS`）。
- **[x] ② 已加自动化测试** — `tools/browser-extension/youtube-bridge-track-priority.test.js` 三例：默认轨排第 14 位仍被抓且排第一、无默认索引按音轨语言码匹配 + 人工轨优先、无提示保持原顺序前 20 条。
- **备注**：服务端兜底路径 `/api/youtube/captions` 不设条数上限，不在本条范围。
