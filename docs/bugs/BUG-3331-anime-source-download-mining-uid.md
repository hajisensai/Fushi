## BUG-3331 · 扩展下载到本地的集制卡失败：Invalid library UID
- **报告**：2026-10-14（反馈 #Gk1hBkIV9F，Android；截图 toast「导出卡片失败：Video source identity could not be verified: FormatException: Invalid library UID」；未下载的集在线播放能制卡）
- **真实性**：✅ 真 bug。在线视频源的集下载后保留原行身份 `bookUid = anime-source:<扩展包>:<源>:<集 url>`（`fushi/lib/src/media/video/online/anime_source_video_client.dart:140-143`；`anime_source_library.dart` 下载后替换同 bookUid 的行）。本地文件制卡时 `resolveSourceLink`（`fushi/lib/src/pages/implementations/video_fushi/lookup_mining.part.dart:497`）用它建 `CardSourceLink`，而 `packages/fushi_anki/lib/src/card_source_link.dart:166`（修复前）把 `^[A-Za-z][A-Za-z0-9+.-]*:` 形态的 UID 一律拒绝 → `fushi/lib/src/mining/immersion_mining_engine.dart:484` 中止整张卡。在线集是远端流、`isLocalPath` 为假、不建来源链接，所以能制卡——正是用户看到的分叉。
- **[x] ① 已修复** — 校验器去掉 scheme 形态拒绝：UID 是不透明的库键，唯一消费方是 `getByBookUid` / `getEpubBookByUid` 等值查找，从不当 URI 解析；拒绝库自己铸造的身份形态是对身份空间的错误建模。绝对路径、上跳段、反斜杠、控制字符、超长照旧拒绝。
- **[x] ② 已加自动化测试** — `fushi/test/anki/card_source_link_uid_test.dart`（用真实前缀 `kAnimeSourceVideoIdPrefix` 构造身份并经卡片 href 往返；危险形态仍拒绝；已做变异实测）。
- **备注**：反馈里顺带提到的「储存占用里看不到下载条目名 / 找不到地方删扩展下载」是另一个问题，本条未处理。
