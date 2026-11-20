## BUG-4979 · 书架删书不清自定义封面，同名书重新导入后旧封面复活
- **报告**：2026-11-20（路线图 #3722 c37 novel-4）
- **真实性**：✅ 真 bug。先在 develop（7745effa2e）上用单测复现：不传 appModel 删书 → 同名书重新导入 → `resolveOverrideThumbnailFile` 仍返回旧封面（dist 跑 1 个测试通过 = 现象成立）。
  - 根因：`fushi/lib/src/media/sources/reader_fushi_source.dart:1057` 的 `deleteBook` 把 `appModel` 设成可选，`:1229` 只有传了才调 `clearOverrideValues`（清封面文件），否则只清 override 书名。override 封面文件名只由 `mediaIdentifier` 派生，而 bookKey = 净化后的书名（`packages/fushi_engine/lib/epub/epub_importer.dart:294`），同名重导拿到同一个 bookKey。书架单删 / 批删、字幕书卡删除（`deleteSrtShelfBook` 根本不收 appModel）、漫画作品页、LNReader 作品页、ctl 两条删除路由、Kavita 淘汰 / 移除下载都没传。
- **[x] ① 已修复** — `deleteBook` 与 `deleteSrtShelfBook` 的 `appModel` 改必填，封面无条件清；全部调用点补齐。`KavitaBookService` 新增 `appModel` 构造参数，只有会删书的两个实例（详情页、设置页）给；没给的实例（进度同步 / 进度刷新，只读写绑定）调删除类方法抛 `StateError`，不再静默漏清。审查补：封面清理原本与有声书持久目录 / 解压目录删除同在一个容错 try 里，前面任一步抛错（Windows 目录被占用 errno 32，TODO-1359 正是常见路径）就连带跳过；现拆成独立的 try，各自记日志。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/media/sources/reader_fushi_delete_cleanup_test.dart`「BUG-4979」组：真实内存库 + 真实删书原语，书架删书 / 配对字幕书卡删除 / Kavita 移除下载（生产删书器）后封面文件不在、同名重导无封面；注入有声书持久目录删除失败后封面照样清（撤掉拆分即红，已变异实测）；未给 appModel 的 Kavita 实例删书抛错且书还在。
- **备注**：不涉及阅读器排版 / 播放；真机「删书后同名重导看封面」未做（本轮所有者定不做设备验证）。
