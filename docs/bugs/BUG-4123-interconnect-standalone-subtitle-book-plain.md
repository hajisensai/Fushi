## BUG-4123 · 互联：独立字幕书（字幕 + 音频、无 EPUB）在对端只显示成一本没有音频的普通书
- **报告**：2026-11-05（fushi_server 有声书库根冒烟测试发现，PR #2939：库根里只有字幕 + 音频的文件夹扫描入库 `audiobooks +1`，`/api/library/audiobooks` 却是空的，`/api/library/books` 只列出一本 `hasAudiobook` 为假的 EPUB）
- **真实性**：✅ 真 bug，app 当 host 同样中（导入函数是同一个）。根因是互联有声书协议还停在旧数据形态：
  - 独立字幕书由 `importStandaloneSubtitleBook`（`packages/fushi_engine/lib/media/audiobook/standalone_subtitle_book.dart`）导入时用 cue 生成一本正文 EPUB，`SrtBooks.bookKey` 指向它，不落 Audiobooks 行（至少 2026-06 起对话框就是这样，3bed24b474 只是把实现搬进引擎）。
  - host 的有声书清单按「bookKey 为空 = 独立字幕书」挑行：`packages/fushi_engine/lib/sync/local_library_host_service/audiobooks.part.dart:79` `if (srt.bookKey.isNotEmpty) continue;`——这类书既不是 srt-backed（没有 Audiobooks 行）又被当成 srt-backed 跳过，整条漏掉；书清单（`books.part.dart`）只把那本正文当普通书列出。
  - 收端包导入同样写死旧形态：`packages/fushi_engine/lib/sync/sync_asset_package_service.dart:606` 把独立字幕书的 `bookKey` 恒写成空串；而书架打开字幕书时 bookKey 为空直接报「正文未就绪」（`fushi/lib/src/pages/implementations/reader_history/books.part.dart:217` `_openSrtBook`），包里也不带正文——就算清单列出来，收下的书也打不开。
- **[x] ① 已修复** — 根因修数据形态判据，不在消费端补丁（本分支提交）：
  1. 判据收成一处（`standalone_subtitle_book.dart`）：`isStandaloneSubtitleBook` = 没有 Audiobooks 行；`srtBookHasGeneratedBody` 排除 EPUB 有声书的配对行（`srtbook_epub_<bookKey>`，正文是用户的书，绝不能按 cue 重写）。
  2. host：`listAudiobooks` 改用该判据，带生成正文的独立字幕书按 uid 列出；`listBooks` 给那本正文标 `subtitleBookBody`（新可选字段，旧 client 忽略、行为不变）。正文仍在清单里：同步推送按清单算「host 缺哪本」，拿掉会让收端把自己生成的正文推回 host。
  3. 收端：`_importStandaloneSrtPackage` 按包里同一份 cue 用同一个生成器再生成正文（`importGeneratedSubtitleBody`，本机导入也改调它），写库失败撤掉刚生成的正文；重新下载沿用本机那本正文、按新 cue 就地重建。`importAudioSubtitlePackage`（只更新字幕）换 cue 后同样重建正文——阅读器按文本相等把 cue 配回正文。重建实现从 app 的 `srt_book_reimport.dart` 移进引擎（`generatedSubtitleBodyRow` / `rebuildGeneratedSubtitleBody`），本机「重新导入字幕」与收包共用。
  4. client 展示：书架远端占位、首页「继续」跳过 `isSubtitleBookBody` 的书（字幕书本身按 uid 出占位，避免同一本书两张卡）；字幕书卡菜单「从互联对端重新拉取」的判据从「bookKey 为空」改成「对端按 uid 列着这本」，收下来的书 bookKey 不再为空也照样有入口。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_library_host_service_audio_test.dart`「纯 SRT standalone 有声书」组：真实本机导入造书 → host 清单按 uid 列出、正文标 `subtitleBookBody`（含 JSON 往返）；EPUB 有声书配对行缺 Audiobooks 行仍不算独立字幕书；host 导出 → client 导入得到可打开的书（bookKey 非空、正文含 cue 文本、无 Audiobooks 行），再下载一次沿用同一本正文；只更新字幕后正文按新 cue 重建。原来断言「独立字幕书 bookKey 恒空」的用例（本组、`sync_asset_package_service_test.dart` 纯 SRT 往返、`interconnect_audiobook_refetch_test.dart` 只更新字幕）改为断言有正文、只更新字幕沿用同一本正文、仍无 Audiobooks 行。收独立字幕书包现在要写正文 EPUB，导入音频包的既有用例组改用新 helper `fushi/test/helpers/engine_storage_sandbox.dart`（固定引擎根 + EPUB 书目录）；`interconnect_audiobook_refetch_test.dart` 的接线守卫从「含 `bookKey.isEmpty &&`」改为「不含 `if (bookKey.isEmpty &&`」（入口只按对端 uid 候选给）。
- **备注**：
  - 修复前已经在 client 上收下的那本「普通书」（正文 EPUB，无音频）不会自动合并：它和之后收下的字幕书是两本，用户可删掉前者。
  - 删除 / 墓碑仍按旧的「bookKey 为空才写 srtbook 墓碑」判据（`audiobooks.part.dart` deleteAudiobook、`SrtBookRepository.delete`）。修复后收端与 host 上的这类书是同一形态，删除行为与本机导入的同类书一致；未改动。
  - 跨设备真机验收（client 书架上出现一张有声书卡、能打开并跟读、只更新字幕后高亮仍对得上）待补。
