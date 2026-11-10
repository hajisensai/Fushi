## BUG-4333 · 文件名 S01E0005 这类 4 位集号识别不出，每集成独立系列
- **报告**：2026-11-08（应用内反馈 H0K31TjWub，iPad / iOS 27.0.1，3.3.0-debug.24438）
- **真实性**：✅ 真 bug，已沿代码路径确认。文件名解析（Rust 胖核心 `FilenameParser.parse` → `ffc_parse_filename_parse_batch`）里两条 SxxEyy / Exx 正则把集号写死成 1–3 位：
  - 根因：`native/fushi_compute/src/parse/media_name.rs:146` `season_episode` 的集号组 `(\d{1,3})`，`S01E0005` 吃到 `000` 后第 4 位 `5` 不是分隔符，前瞻 `(?=$|[\s._-])` 失败、整条不匹配；`:150` `ep_token`（`E\.?(\d{1,3})`）同样限制。集号解析失败后整个 stem 当标题，`groupVideosIntoPlaylists` 按标题分组 → 每个文件各成一个系列。兄弟差分定号（`video_filename_parser.dart` `_pureEpisodeDigits` 1–3 位、为挡年份目录刻意不收 4 位）也救不回来。同文件 `cn_episode` / `cn_episode_suffix` / `dash_episode` 早已收 1–4 位，口径不一致。
- **[x] ① 已修复** — `season_episode` 与 `ep_token` 集号放宽到 `\d{1,4}`，与 `cn_episode` 等同口径。两者都有字母前缀（`S..E` / `E` / `EP`）和两侧分隔约束，年份（裸 `19xx/20xx`）与 `1080p` 之类 token 天然区分开，不加按数值的特例。`hash_episode`（`#\s*(\d{1,3})`）刻意不放宽：它没有尾部分隔约束，放宽会把 `#1080p` 读成集号 1080，已在源码注释说明。
- **[x] ② 已加自动化测试** — Rust `media_name.rs` `four_digit_episode_numbers`（S01E0005 / S01E0123 / S1E1000 / E0012 / EP1000、年份与 4 位集号并存、反例 S01E12345 不截断、E1080p 不是集号）；Dart FFI 金样 `fushi/test/media/video/scraper/filename_parser_test.dart`「4 位补零集号」；分组 `fushi/test/media/video/video_filename_parser_test.dart`「4 位补零集号 S01E0005 归同一系列」。
- **备注**：测试未在本分支运行，统一在合并后验证。YUH015QaF2（Windows 系列页「按作品刮削后」每集一张卡）日志里没有文件名，无证据指向同一正则；其现象出现在刮削身份确认环节（横幅「2 部作品身份未确认」），按另一簇处理。
