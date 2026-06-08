## BUG-138 · Hibiki互联导出书籍包结构错误且有声书列表暴露孤儿行
- **报告**：2026-06-08（用户：Hibiki互联手机同步电脑数据时 6 个失败；4 本书报 `Invalid EPUB: missing META-INF/container.xml`，2 本有声书报 `/api/library/audiobooks/...` 404）
- **真实性**：✅ 真 bug — 书籍导出路径在 `hibiki/lib/src/sync/sync_manager.dart:27-39` 直接打包 `extractDir`，没有校正“外层目录/真实 EPUB 根目录”错位；有声书列表在 `hibiki/lib/src/sync/app_model_library_host_service.dart:342-365` 原本只读 `Audiobooks`，但导出同时要求 `SrtBooks` 行存在，导致列表可见而 GET 404。
- **[x] ① 已修复** — 提交 `5ec1f7da5`
- **[x] ② 已加自动化测试** — `hibiki/test/sync/hibiki_library_host_service_books_test.dart` + `hibiki/test/sync/hibiki_library_host_service_audio_test.dart`
- **备注**：历史日志里的 settings segmented callback 类型错误发生在 2026-05-27/28，和本次 2026-06-08 互联导出失败不是同一条路径。

### 根因
Hibiki 互联的书籍 live pull 走手机端 `GET /api/library/books/<title>`，电脑端由 `AppModelLibraryHostService.exportBook()` 调用 `repackageExtractedEpub()` 把已解包的书重新压成 `.epub`。手机端导入时要求 zip 根目录存在 `META-INF/container.xml`。

用户电脑上“能正常读”的书不等于“能被互联导出”：阅读器可能仍能通过 DB 缓存路径或当前本机布局打开内容，但互联导出必须把 EPUB 根目录放在 zip 顶层。旧逻辑只要 `extractDir` 存在就把它整目录压包；当 `extractDir` 指到外层目录、真实 EPUB 根目录在唯一子目录中时，导出的包会变成 `EPUB_ROOT/META-INF/container.xml`，手机端因此报 `Invalid EPUB: missing META-INF/container.xml`。

有声书 live pull 的失败是另一处列表/导出契约不一致：`listAudiobooks()` 只根据 `Audiobooks` 行暴露条目，但 `exportAudiobook()` 需要同时找到 `Audiobooks` 与 `SrtBooks`。孤儿 `Audiobooks` 行会进入远端列表，随后 GET 时因为缺 `SrtBooks` 被映射为 404。

### 修复
- `repackageExtractedEpub()` 改为先解析可导出的 EPUB 根目录：当前 `extractDir` 本身含 `META-INF/container.xml` 时直接使用；否则允许外层目录下唯一一个含 `META-INF/container.xml` 的直接子目录作为真实根目录。
- `AppModelLibraryHostService.listBooks()` 与 `exportBook()` 复用同一个 EPUB 根目录解析逻辑，让列表的 `hasContent` 与实际导出能力一致。
- `listAudiobooks()` 只暴露同时存在 `SrtBooks` 的有声书，并把 `SrtBooks.title` 带回列表，避免手机端拉取必然 404 的孤儿条目。

### 验证
- 红测：`D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\sync\hibiki_library_host_service_books_test.dart` 曾失败在 `archive.findFile('META-INF/container.xml')` 为 null。
- 红测：`D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\sync\hibiki_library_host_service_audio_test.dart` 曾失败在孤儿有声书仍被 `listAudiobooks()` 返回。
- 修复后：`D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\sync\hibiki_library_host_service_books_test.dart`
- 修复后：`D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\sync\hibiki_library_host_service_audio_test.dart`
