## BUG-5237 · 互联漫画按页序取图不核页身份：host 重解析出换了页的页表后端出另一页
- **报告**：2026-11-22（代码审查 HBK-AUDIT-205，`docs/reviews/2026-11-22-project-review.md`，针对 PR #4139）
- **真实性**：✅ 真 bug。PR #4139 让 host 页表报每页的源端身份、客户端下载续跑按身份记账，但取图请求只带章与页序：
  - 客户端 `fushi/lib/src/media/manga/interconnect/interconnect_manga_source.dart:256`（develop 283a920286）`fetchRemoteMangaPage(bookKey, remoteIndex)` / `fetchRemoteMangaChapterPage(…, remoteIndex)` 不带身份。
  - host `packages/fushi_engine/lib/sync/local_library_host_service/manga.part.dart` `_onlineChapterPageFile` 先 `chapterPageKeys` 取身份定缓存文件名，再 `chapterPage(index)` 另取一次页表取图；`InterconnectOnlineMangaHostReader` 页表缓存只留 8 章，两次之间被淘汰或 host 重启，就会按重解析出的新页表取第 index 页。
  - 结果：旧页表 [A,B,C]、新页表 [B,A,C] 时，客户端取第 0 页拿到 B 的字节，下载账本记成 A；host 也会把 B 落到 A 身份的缓存文件名下，之后一直端错。
- **[x] ① 已修复** — 取图请求带页身份摘要（查询参数 `pageKey` = `remoteMangaPageKeyDigest(RemoteMangaPageInfo.key)`）。host 在同一份页表上核对（已下载章 / 单卷按文件身份，现取章由运行时 `OnlineMangaHostReader.chapterPage(expectedPageKey:)` 在取图所用的那份页表上核对），对不上抛 `MangaPageChanged` → 409。客户端把 409 当成页引用过期（`OnlineMangaPageRefExpired`），交给 `OnlineMangaChapterPageRefs` 重取页表逐页比对：换了页就判 `pageTableChanged`（阅读器报失败，下载按新页表重新对账），没换就用新引用再取。wire 双向兼容：旧 host 忽略参数，旧 client 不带参数。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/interconnect_manga_source_test.dart`（真 server + 真 backend：host 页表 [A,B]→[B,A] 后按旧页序取图被拒、判换页、新表取到正确页）；`fushi/test/sync/local_library_host_service_manga_test.dart`（已下载章 / 现取章的身份核对、取身份与取图之间页表被换时运行时拒取）；`fushi/test/media/manga/interconnect/interconnect_online_manga_host_reader_test.dart`（host 重启后重解析出换了页的页表，按旧身份取图抛 `MangaPageChanged`）。
- **备注**：与 BUG-5238 同属 audit-035（PR #4139）的页身份链。
