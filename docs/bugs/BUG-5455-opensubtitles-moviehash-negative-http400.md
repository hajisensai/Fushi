## BUG-5455 · 字幕面板「字幕搜索失败（HTTP 400）」：OpenSubtitles movie hash 拼出负号，日志里没有任何线索
- **报告**：2026-11-25（用户：应用内反馈 0W5jBpKNlu，Windows 3.4.0+32563；字幕页填了 Jimaku key，番名「凶乱令嬢ニア・リストン …」、集数 8，顶部红条「字幕搜索失败（HTTP 400）」+「没有找到字幕」，上传日志里没有任何字幕相关行）
- **真实性**：✅ 真 bug，与 Jimaku 无关。
  - 根因 `packages/fushi_engine/lib/media/video/download/video_subtitle_registry.dart:148`（修前）：`computeOpenSubtitlesMovieHash` 用有符号 Dart int 累加 uint64，最后 `hash.toRadixString(16)`；累加结果最高位为 1（约一半的视频文件）时拼出 `-1a77f0c52a92c101` 这种带负号的串。OpenSubtitles 对它回 `400 Request parameters do not make sense: moviehash must be 16 hex characters`（2026-11-25 实测：参数校验先于鉴权，不带 key 也是 400；合法的 16 位 hash 不带 key 回 403）。原来的 `& 0xffffffffffffffff` 在 Dart 里就是 `& -1`，什么也没做。
  - 放大：`open_subtitles_client.dart:625` hash 档非 2xx 即抛（有意：精确档失败不退宽档），于是整次 OpenSubtitles 搜索作废；Jimaku 这次零命中（不进 failures），`subtitle_search_panel.dart:1012` 挑出唯一的失败，`describeSubtitleFailure` 对 `unavailable` 走 `_ => baseMessage`（`:292`），红条只剩「字幕搜索失败（HTTP 400）」，不点名来源，用户自然以为是 Jimaku 坏了。
  - 诊断缺口：`video_subtitle_registry.dart:50` 合并各来源结果后，失败只当返回值交给 UI，任何入口都不写日志，所以反馈日志里一行线索都没有。
  - 已排除 Jimaku：`/api/entries/search` 的 400 只出在 query string 反序列化失败（`anime` 非 true/false、`anilist_id` 非数字或越界、`tmdb_id` 不合 `(tv|movie):\d+`），本次请求的这几个参数都合法；`/entries/{id}/files?episode=8` 也合法。
- **[x] ① 已修复** — `formatOpenSubtitlesMovieHash` 按高低 32 位无符号拼 16 位十六进制；`VideoSubtitleRegistry.search` 把每条来源失败（来源、操作、状态码）记进诊断日志（随反馈日志上传）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/open_subtitles_movie_hash_test.dart`：最高位为 1 / 全 0xff / 伪随机文件与 BigInt 参照实现逐位一致且满足服务端 `^[0-9a-f]{16}$`；假 OpenSubtitles 服务端按真实校验规则回 400，hash 档不再作废整次搜索；registry 失败逐条进诊断日志、全成功时不写。修前 5 条红。
- **备注**：红条不点名来源（`describeSubtitleFailure` 的 `_ =>` 分支）属 UI 文案改动，本次未动，留作后续。
