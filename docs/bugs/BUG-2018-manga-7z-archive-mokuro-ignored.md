## BUG-2018 · RAR/CBR/CB7 漫画包内嵌与旁挂 mokuro OCR 不被识别

- **报告**：2026-09-01（合流审查发现，非用户报告）
- **真实性**：✅ 真 bug（能力空洞）。根因
  `fushi/lib/src/media/manga/import/manga_archive_importer.dart:318`
  —— `importArchive` 的 7-Zip 分支（`_kSevenZipMangaArchiveExtensions`）把 RAR/CBR/CB7
  交给外部 `7za` 解压，**整条路径上没有 `package:archive` 的 `Archive` 对象**；
  而 mokuro 识别入口 `_findMokuroCandidate(Archive, String)`
  （同文件 `:352`）只在 ZIP/CBZ/EPUB 分支内被调用。
  于是 RAR/CBR/CB7 包里的 `.mokuro` 成员**和**同名旁挂 `book.cbr.mokuro` /
  `book.mokuro` 都不会被读到，整卷退化成无文字层的纯图漫画。

  **这不是任一 PR 单独的 bug**：PR #1117（CBZ 内嵌 mokuro OCR）只覆盖
  `package:archive` 能解的容器；PR #1114（纯图目录 + RAR/CBR 包）新开的 7z 分支
  在 #1117 之后才与之相遇。空洞是两条改动**合流后**才出现的。

  合流时的显式决定：把 mokuro 识别块放进 **ZIP 分支内部**，而不是悬在分支外对可空
  `archive` 做隐式判断。后者会让「7z 包的 mokuro 被静默丢弃」看起来像是已支持，
  且 `_findMokuroCandidate` 收到 `null` 时无法区分「没有 manifest」与「这个容器根本
  没被解析过」—— 而这两者的正确行为不同（前者继续走纯图导入，后者应当补齐能力）。

- **[ ] ① 未修复** —— 需要把 mokuro 发现从「吃 `Archive`」抽象成「吃条目清单 +
  按名取字节」的容器无关接口，让 7-Zip 分支也能提供成员列表与内容读取；
  旁挂 `.mokuro` 那半段（`_findMokuroCandidate` 里读磁盘 sidecar 的部分）与容器
  无关，可以先行提取给两条分支共用。
- **[ ] ② 未加自动化测试** —— 修复时应在
  `fushi/test/media/manga/manga_archive_importer_test.dart` 补：
  ① 假 7z runner 提供含 `.mokuro` 成员的 RAR 列表 → 断言导入结果带文字层；
  ② `book.cbr` + 同名旁挂 `book.mokuro` → 断言 OCR 被采纳。
- **备注**：现状是**静默退化**（导入成功、只是没有文字层），不是报错，所以用户不易
  察觉。当前 PR 只做合流、不扩大范围；本条作为已知缺口单独记账。
