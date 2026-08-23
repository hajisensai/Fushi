## BUG-1779 · 制卡媒体文件名仍带 hibiki 旧名前缀

- **报告**：2026-08-23（用户：制卡的文件名怎么还叫 hibiki，换成 fushi）
- **真实性**：✅ 真 bug。改名（Hibiki → Fushi）W9 收尾只清了 Anki 媒体前缀里的 `hibiki_audio_`（见 `docs/plans/2026-08-06-rename-fushi-progress.md:111`），同族的另外三个前缀漏在原地，且 `fushi_rename_guard_test.dart` 的禁模式一条都没盖到它们，于是漏改没有任何守卫会报。落进用户 Anki collection.media 的旧名共三处根因：
  - `packages/fushi_anki/lib/src/anki_models.dart:1010` — `ankiDictionaryMediaCacheFilename` 产出 `hibiki_dict_<sha1>.<ext>`，三端（AnkiConnect / AnkiDroid / AnkiMobile）**原样当 Anki media 文件名**用；iOS 侧还把它塞进 `/media/<id>-<name>` URL，用户直接看得见。
  - `packages/fushi_anki/lib/src/ankidroid/anki_repository.dart:671` 与 `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart:814` — 封面 / `{card-image}` / `{video-clip}` 的 `hibiki_cover_` 前缀。
  - `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart:167` — `_safeMediaPrefix` 兜底常量 `hibiki_media_`（现有三个实参都合法，实际不可达，但仍是旧名真源）。

- **[x] ① 已修复** — 改命名真源，不在各端加特例：`hibiki_dict_` → `fushi_dict_`、`hibiki_cover_` → `fushi_cover_`、`hibiki_media_` → `fushi_media_`。词典媒体的 writer 与三个 backend 本来就共用同一个 helper，改一处四个读写点自动对齐。顺带把制卡链路上的进程内临时名统一到 `fushi_`（`fushi_mine_sentence_audio_` / `fushi_ankimobile_media_` / `fushi_word_audio_` / `fushi_gal_gif_` / `fushi-gal-card-job-` / `fushi-gal-mining-job-`），以及与 `hibiki_dict_` 撞词根的两个同步临时名（`fushi_dict_export` / `fushi_dict_in`）——后者是为了让 ② 的守卫词根不必开例外。提交哈希：`4e42ba2f72`。

  **零破坏性论证**：生产代码里**没有任何一处按前缀识别媒体**——AnkiConnect 去重走「全量列举 + 同大小才算 sha256 + 删前逐字节复核」，事务回滚按记录的确切文件名删，AnkiDroid staging 只判断是否在 systemTemp 下，Android `AnkiChannelHandler.java` 纯透传 `preferredName`。故改名只影响**新产出**：存量卡片字段里写死的 `hibiki_cover_*` 引用继续指向 collection.media 里已存在的旧文件，照常显示。这与 W9 当初改 `hibiki_audio_` → `fushi_audio_` 是同一先例。

- **[x] ② 已加自动化测试** — `fushi/test/tools/fushi_rename_guard_test.dart` 新增禁模式 `hibiki_* Anki 媒体文件名前缀`（`RegExp(r'hibiki_(?:cover|dict|media|audio)_')`，无白名单），扫 `fushi/lib` + 六个 `packages/fushi_*/lib`。**变异实测**：把 `anki_models.dart` 的返回值改回 `hibiki_dict_$digest.$ext` → 守卫红并精确报出 `[hibiki_* Anki 媒体文件名前缀] packages/fushi_anki/lib/src/anki_models.dart:1014 → hibiki_dict_`；还原后 SHA-256 与变异前逐字节一致（`87002AA2…D71601`）。口径只圈**进得了 Anki 的媒体名**，不含 `hibiki_gal_gif_` 那类进程内不可见的 systemTemp 前缀族（它们的对外名在上传时被重算成 `fushi_<sha256>`），与相邻那条「用户可见导出文件名」守卫的注释口径一致。

  同批更新锁死旧名的既有测试金标：`packages/fushi_anki/test/` 下 `media_filename_guard_test.dart` / `card_image_video_mining_e2e_test.dart` / `mining_isolate_offload_test.dart` / `ankidroid_cover_fileprovider_stage_test.dart` / `dictionary_media_missing_degrades_test.dart` / `ankiconnect_service_test.dart` / `handlebar_card_image_test.dart` / `handlebar_video_clip_test.dart`，以及 `fushi/test/anki/anki_dict_media_cache_test.dart` / `anki_dict_media_embed_test.dart`。sha1/sha256 摘要值本身不变（哈希输入没动），只换前缀。

- **备注**：词典媒体缓存名 `fushi_dict_<40 位 sha1 hex>` 与 popup.js 注入的占位符 `fushi_dict_<序号>` 现在同前缀。两者不会互相误伤——`BaseAnkiRepository.buildMinedFields` 的 `replaceAll` 拿占位符当 key，而真名中段恒为 40 位 hex，永远匹配不上 `fushi_dict_0.svg` 这种序号形态，故不会二次替换自己的产物。此不变式已写进 `anki_models.dart` 的函数注释。
