## BUG-4710 · 浏览器扩展：ASS 字幕两句时间重叠时覆盖层只显示一句
- **报告**：2026-11-16（用户：应用内反馈 -Rbr-U5FNr，浏览器扩展给网页视频挂外挂 ASS，两位说话人台词同时开始）
- **真实性**：✅ 真 bug。根因：覆盖层是单 cue 模型——`tools/browser-extension/subtitle-panel.js` 的 tick（develop 上 :347-348）用 `cueIndexAt`（:202-210）只取「startMs <= t 的最后一条」并只把这一条交给 `updateSubtitleOverlay` / `renderOverlayCue`。字幕轨只按 startMs 排序、允许时间重叠：同起点的两句只画后一句；起点更早的长句在后一句结束后，`cueIndexAt` 返回 -1，整块字幕消失。
- **[x] ① 已修复** — 覆盖层改成「此刻全部有效 cue」的集合模型：新增 `activeCueIndicesAt`（二分到最后一条已开始的 cue，再向前扫出所有 `t < endMs` 的），`st.overlayCue` → `st.overlayCues`、`overlayRenderedCue` → `overlayRenderedCues`；多条时每条一个 `.fushi-subtitle-overlay-line` 块级行（轨内顺序），点击 / 悬浮查词按指针所在行取对应 cue 的时间窗（`overlayCueForNode`）。镜像 `fushi/assets/browser_extension/subtitle-panel.js` 同步。
- **[x] ② 已加自动化测试** — `tools/browser-extension/external-subtitle.test.js`「⑤b 时间重叠的 cue 同时叠字」：同起点两句都画、点第二行查词带第二行的 cue、短句结束后长句仍在、交错重叠两句同屏。修复前红（actual 只有 `ニア！言い方！`）。
- **备注**：未在真实浏览器里肉眼复测（vm 壳内覆盖层 DOM 断言）。`cueIndexAt` / `subtitle-adapters.js findCueIndexAt` 给快捷键、学习统计、制卡取句用的「单句」判据未改（仍是起点最晚那条、长句后半段返回 -1），侧栏字幕列表高亮也仍是单行，不在本条范围。
