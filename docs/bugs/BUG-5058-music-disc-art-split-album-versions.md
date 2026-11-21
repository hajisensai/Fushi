## BUG-5058 · 同一张 CD 的另一个版本目录（如 24bit 版）不显示盘面图
- **报告**：2026-11-21（用户：BUG-5057 修复后追问「24bit 版本不会显示唱片，修一下」）
- **真实性**：✅ 真 bug。盘面图按专辑 uid 找（`fushi/lib/src/media/music/music_disc_art.dart` `MusicDiscArtIndex.resolve` 遍历该 uid 全部版本目录）。专辑艺人标签一致时两份目录合成一个 uid（`native/fushi_music` `uid.rs` 的 `album_uid`），本来就共享；标签不一致时被拆成两张专辑——用户库里 `アイデン貞貞メルトダウン`（一份有专辑艺人一份没有）、`ひめごと＊クライシスターズ` / `ひめごと*クライシスターズ`、`サウンドスケープ`（`TRUE` / 笔误 `TURE`）——扫图只在 `(flac+webp)` 那份目录，`[24bit_…] (flac)` 那份的 uid 没有任何根目录带扫图，结果为空。
- **[x] ① 已修复** — `shareMusicDiscArtAcrossVersions`：专辑名比较键（`musicAlbumTitleKey`，全角折半角、空白归一、小写）相同、且版本目录在同一个父目录下的专辑视为同一张的不同版本，没有盘面图的借用有图的那份；曲库页 `_resolveDiscArt` 发布前补全。只比同一父目录，不跨目录同名匹配。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_disc_art_test.dart`「同一张专辑的各版本共用盘面图」组：拆开的两版本借用、分碟目录并回版本目录、跨父目录同名 / 同目录异名不借、比较键归一。
- **备注**：没改专辑拆分本身（那是扫描器按标签聚合的口径，标签不一致的两份在专辑墙上仍是两张）。真机肉眼复测未做。
