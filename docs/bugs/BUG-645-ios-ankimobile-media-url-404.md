## BUG-645 · iOS AnkiMobile 制卡本地媒体 URL 404
- **报告**：2026-07-07（用户：wight）
- **真实性**：✅ 真 bug。用户在 BUG-644 修复后真机实测反馈 Anki 制卡媒体 URL 报 404。根因是 `hibiki/lib/src/anki/ankimobile_repository.dart:465` 的 AnkiMobile 本地媒体 server 注册媒体时直接保存原始 `File` 引用，而 reader 制卡路径在 `hibiki/lib/src/pages/implementations/reader_hibiki/mining.part.dart:191` 的 `finally` 中会立刻执行 `prepared.cleanup()` 删除句音频临时目录；AnkiMobile 稍后异步 GET localhost URL 时，`_handleRequest` 在 `hibiki/lib/src/anki/ankimobile_repository.dart:516` 看到源文件不存在，就返回 404。
- **[x] ① 已修复** — `962c3cc37`：AnkiMobile media server 启动时创建自己管理的临时目录，`addFile()` 注册媒体时先复制一份快照到该目录，URL 服务期间只读取快照文件；server 关闭时统一删除快照目录。这样 reader/video 调用方可以按原生命周期清理源临时文件，不会影响 AnkiMobile 后续下载。
- **[x] ② 已加自动化测试** — `962c3cc37`：`hibiki/test/anki/ankimobile_repository_test.dart` 新增 `media URLs survive source temp cleanup until AnkiMobile fetches`，复现 `mineEntry()` 返回后删除源临时目录，再用 socket GET AnkiMobile media URL；修复前返回 `HTTP/1.1 404 Not Found`，修复后返回 200 且字节一致。
- **备注**：这是 BUG-644 之后暴露出来的第二段链路问题：`.m4a` 让 AnkiMobile 开始识别并抓取媒体 URL，随后才撞到源文件被过早清理的 404。
