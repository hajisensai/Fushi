## BUG-3820 · 视频解析器不认 Second Season / Season Two 等英文序数季名，合集包续季目录判不出季号
- **报告**：2026-10-27（应用内反馈 kg41f2PGdC 的遗留项，见 BUG-3816 备注）
- **真实性**：✅ 真 bug。季号规则只认数字形式：`native/fushi_compute/src/parse/media_name.rs:155`（修前）`ordinal_season` = `(\d{1,2})\s*(?:st|nd|rd|th)\s*Season`、`season_word` = `Season[\s._]*(\d{1,2})`，`parse_title_text` ④ 季度模式（修前 `:657-671`）里没有任何英文序数词 / 基数词规则。于是 `[VCB-Studio] Yama no Susume Second Season [01]...mkv` 与其目录名 `season` 均为 null；BUG-3816 的整理器只能把 `Second Season` / `Third Season` 目录当作「并列作品」镜像落位，而不是按季并进同一合集。
- **[x] ① 已修复** — `media_name.rs` 新增两条规则 `word_ordinal_season`（`(first|second|…|tenth)[\s._]+Season`）与 `season_cardinal_word`（`Season[\s._]+(one|two|…|ten)`），大小写不敏感、要求两侧是分隔符边界，只在与 `Season` 直接相连的词组里认（裸 `Second` / `Two` 不算）；在 ④ 里排在数字序数规则之前，季名从标题里剥掉（与 `2nd Season` 同口径）。罗马数字 `II/III/IV` 结尾沿用既有 `ascii_roman_tail`，未扩大。整理器 `video_download_organizer.dart` 无需改：文件名 / 目录名一旦解出季号，`_packSeasonLayout` 就把它们排除出「并列作品」判定并按季落位。
- **[x] ② 已加自动化测试** —
  - Rust：`media_name.rs` `tests::english_ordinal_season_words`（11 例，含大小写、点分隔、`Season Two/Ten`、既有 `2nd Season`、3 个负样本 `Second Chance` / `Two Seasons Later` / `The Seasoned Second`）；crate 全量 `cargo test --lib` 186 passed。变异：`english_number_word` 恒返回 None → 该测试红。
  - Dart：`fushi/test/media/video/video_filename_parser_test.dart` 组「parseVideoPath：英文序数词季名目录」（4 例）；`fushi/test/media/video/download/video_download_organizer_test.dart` 组「multi-directory packs (kg41f2PGdC)」扩展用户原包完整形态（本作 + Second Season + Third Season + Next Summit + SPs）→ S01/S02/S03 并进同一作品、Next Summit 仍为并列作品、目标唯一；另加 `Season One/Two` 目录例。与 `scraper/filename_parser_test.dart` 同跑 158/158 绿（用本分支源码新编的 `fushi_compute.dll`）。
- **备注**：
  - 这是扩充规则不是搬迁，没有删除旧实现，故不需要「旧实现固定向量」；既有 Rust / Dart 解析测试全绿即旧输出未变。行为变化：标题里带 `Second Season` 等的文件，系列名不再含季名、季号变为对应数字（与 `2nd Season` 一致），会影响此类文件的分组键与刮削搜索词。
  - 未验证：真机整理一个真实 VCB 合集包。`Final Season` 无法映射数字，不认。
