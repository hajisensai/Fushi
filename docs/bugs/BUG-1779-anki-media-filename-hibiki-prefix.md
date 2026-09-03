## BUG-1779 · 制卡媒体文件名仍带 hibiki 旧名前缀

- **报告**：2026-08-23（用户：制卡的文件名怎么还叫 hibiki，换成 fushi）
- **真实性**：✅ 真 bug。改名（Hibiki → Fushi）W9 收尾只清了 Anki 媒体前缀里的 `hibiki_audio_`（见 `docs/plans/2026-08-06-rename-fushi-progress.md:111`），同族的另外三个前缀漏在原地，且 `fushi_rename_guard_test.dart` 的禁模式一条都没盖到它们，于是漏改没有任何守卫会报。落进用户 Anki collection.media 的旧名共三处根因：
  - `packages/fushi_anki/lib/src/anki_models.dart:1010` — `ankiDictionaryMediaCacheFilename` 产出 `hibiki_dict_<sha1>.<ext>`，三端（AnkiConnect / AnkiDroid / AnkiMobile）**原样当 Anki media 文件名**用；iOS 侧还把它塞进 `/media/<id>-<name>` URL，用户直接看得见。
  - `packages/fushi_anki/lib/src/ankidroid/anki_repository.dart:671` 与 `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart:814` — 封面 / `{card-image}` / `{video-clip}` 的 `hibiki_cover_` 前缀。
  - `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart:167` — `_safeMediaPrefix` 兜底常量 `hibiki_media_`。全仓 9 个 `prefix:` 字面量实参（`ankiconnect_repository.dart:814/822/1984/1997/2043` + `ankidroid/anki_repository.dart:671/683/724/736/774`，共 2 个取值）全都通得过 sanitize，所以这条兜底实际不可达；但它仍是旧名真源，留着就是等哪天新增一个会被 sanitize 成空串的 prefix 时冒出来。

- **[x] ① 已修复** — 改命名真源，不在各端加特例：`hibiki_dict_` → `fushi_dict_`、`hibiki_cover_` → `fushi_cover_`、`hibiki_media_` → `fushi_media_`。词典媒体的 writer 与三个 backend 本来就共用同一个 helper，改一处四个读写点自动对齐。顺带把**制卡链路上**的进程内临时名统一到 `fushi_`，共 9 个：`fushi_mine_sentence_audio_`、`fushi_ankimobile_media_`、`fushi_word_audio_`、`fushi_fwd_mine_`（互联转发制卡）、`fushi_pdf_mine_`（PDF 制卡）、`fushi_gal_gif_`、`fushi_gal_track_preview`、`fushi-gal-card-job-`、`fushi-gal-mining-job-`；另加与 `hibiki_dict_` 撞词根的两个**同步**临时名（`fushi_dict_export` / `fushi_dict_in`）——后者与制卡无关，改它们纯粹是为了让 ② 的守卫词根不必开例外。

  这些临时名用户看不见（上传时对外名被 `fushiAnkiMediaFilenameForBytes` 按字节重算成 `<prefix><sha256>.<ext>`），改它们只为消除「同一文件里 `fushi-gal-mining-job-` 与 `hibiki_gal_track_preview` 并存」这种会被误读成有意为之的不一致。**范围边界**：同步 / 漫画导入 / 备份 / 视频导出等子系统里还有 ~30 个 `hibiki_*` systemTemp 前缀，不在制卡链路上，本条目不动它们。提交哈希：`4e42ba2f72`（主体）、`c56c9040a9`（审查后补齐的 4 处临时名与守卫注释修正）。

  **零破坏性论证**：生产代码里**没有任何一处按前缀识别媒体**——AnkiConnect 去重走「全量列举 + 同大小才算 sha256 + 删前逐字节复核」，事务回滚按记录的确切文件名删，AnkiDroid staging 只判断是否在 systemTemp 下，Android `AnkiChannelHandler.java` 纯透传 `preferredName`。故改名只影响**新产出**：存量卡片字段里写死的 `hibiki_cover_*` 引用继续指向 collection.media 里已存在的旧文件，照常显示。这与 W9 当初改 `hibiki_audio_` → `fushi_audio_` 是同一先例。

  **一处例外，方向是好的**：用户主动跑「媒体去重」时，`packages/fushi_anki/lib/src/anki_media_dedup.dart:95-106` 的 `chooseCanonicalMediaName` 排序是「`_` 前缀优先 → 名字更短 → 字典序」。同一张图的存量 `hibiki_cover_<sha>.jpg` 与新产 `fushi_cover_<sha>.jpg` 字节相同会落进同一组，而 `fushi_cover_`（12 字符）比 `hibiki_cover_`（13）短 → 新名胜出为保留份，旧副本被删、老卡片字段里的引用被改写成新名。这是无损的（先改写引用、`ankiconnect_repository.dart:1359-1377` 逐字节复核通过才删），也正是我们想要的收敛方向；但它意味着「旧引用永远不动」只在没跑过去重时成立，故在此写明。

- **[x] ② 已加自动化测试** — `fushi/test/tools/fushi_rename_guard_test.dart` 新增禁模式 `hibiki_* Anki 媒体文件名前缀`（`RegExp(r'hibiki_(?:cover|dict|media|audio)_')`，无白名单），扫 `fushi/lib` + 六个 `packages/fushi_*/lib`。**变异实测**：把 `anki_models.dart` 的返回值改回 `hibiki_dict_$digest.$ext` → 守卫红并精确报出 `[hibiki_* Anki 媒体文件名前缀] packages/fushi_anki/lib/src/anki_models.dart:1014 → hibiki_dict_`；还原后 SHA-256 与变异前逐字节一致（`87002AA2…D71601`）。**口径是按词根圈、不是按用途圈**，因此比「Anki 媒体名」过火——`hibiki_dict_` 会连带命中任何同前缀的 systemTemp 目录名，哪怕与 Anki 无关。这是取舍不是疏漏：四个词根都足够特征化，收窄成 `hibiki_dict_[0-9a-f]{40}` 这种形态匹配只会让守卫变脆且读不懂，多报好过漏报。代价已经付过一次（上面那两个同步临时名就是撞词根被迫改的），将来再撞上同词根的无关临时名，**优先跟着改名**而不是加白名单——白名单在该文件里的语义是「迁移必须读旧名」，纯 `createTemp` 前缀套不上这个理由。反过来，`hibiki_` 后不是这四个词之一的临时名不被本条覆盖。

  同批更新锁死旧名的既有测试金标：`packages/fushi_anki/test/` 下 `media_filename_guard_test.dart` / `card_image_video_mining_e2e_test.dart` / `mining_isolate_offload_test.dart` / `ankidroid_cover_fileprovider_stage_test.dart` / `dictionary_media_missing_degrades_test.dart` / `ankiconnect_service_test.dart` / `handlebar_card_image_test.dart` / `handlebar_video_clip_test.dart`，以及 `fushi/test/anki/anki_dict_media_cache_test.dart` / `anki_dict_media_embed_test.dart`。sha1/sha256 摘要值本身不变（哈希输入没动），只换前缀。

- **备注**：词典媒体缓存名 `fushi_dict_<40 位 sha1 hex>` 与 popup.js 注入的占位符 `fushi_dict_<序号>` 现在同前缀。两者不会互相误伤——`BaseAnkiRepository.buildMinedFields` 的 `replaceAll` 拿占位符当 key，而真名中段恒为 40 位 hex，永远匹配不上 `fushi_dict_0.svg` 这种序号形态，故不会二次替换自己的产物。此不变式已写进 `anki_models.dart` 的函数注释。
