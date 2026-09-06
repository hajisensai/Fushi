## BUG-2194 · 扩展 YouTube 轨枚举被 12 条上限截掉原语言英语轨
- **报告**：2026-09-06（用户截图：Fushi 侧栏字幕列表里俄/孟/德/旁遮普/日/法/波/荷/葡/阿/韩/马拉雅拉姆 12 条齐全，唯独没有英语；YouTube 原生菜单里有「英语（自动生成）」；「而且还缺少英语」）
- **真实性**：✅ 真 bug。`tools/browser-extension/youtube-bridge.js` `fetchAndPublish` 为了不把整集轨 × N 全拉下来，按 YouTube 给的原始顺序只取前 **12** 条 `captionTracks`。自动配音视频每种配音语言各带一条 ASR 轨（几十条），原语言（用户正在听的音轨、也就是学习语言）排在后面就被截掉——用户列表正好 12 条、无英语。
- **[x] ① 已修复** — 按需加载（用户拍板「改成缓加载或按需加载」，不再靠排序 + 上限）：桥先发整份轨清单 `{__fushiStream:'tracks'}`（只有标签，不设上限），只急取排优先级后的头一条（当前音轨默认字幕轨 / 同语言 / 人工轨，`prioritizeCaptionTracks`）让覆盖层与替代原生立即可用；隔离世界 `subtitle-providers.js` 把清单登记成空 cue 的占位轨（`fushiLazyTracks`），面板 `subtitle-panel.js` 把占位轨列在已加载轨之后（侧栏显示「选中加载」），用户选中即 `fushiRequestLazyTrack` → 桥收 `{__fushiStream:'fetchTrack'}` 真取（取过重放缓存、在途去重、同 key 5 秒内不重复请求）。占位轨永远不当主路径（`pickPrimaryCueTrack` / `fushiHasFullEpisodeTrack` 跳过空轨）。`replayCues` 连清单一起重放。
- **[x] ② 已加自动化测试** — `youtube-bridge-track-priority.test.js`（清单 25 条全在含英语、只急取默认一条、fetchTrack 按需取 + 缓存重放 + 未知轨忽略、replay 连清单重放、语言码匹配与人工轨排序）；`lazy-tracks.test.js`（占位登记/不覆盖真 cue/通知面板、请求与标记清除、占位不当主路径）；`subtitle-panel.test.js` 末尾（占位轨排序与 pending 字段、选中触发请求、5 秒节流、cue 到后变普通轨）。
- **备注**：服务端兜底路径 `/api/youtube/captions` 只在桥 8 秒没拿到轨时触发，不受影响。
