## BUG-2492 · 远端媒体下载后合集归属丢失
- **报告**：2026-09-13（用户要求共享收养服务，包含在线漫画）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_history/remote.part.dart` 的 `_runRemoteBookDownload` 与 `_adoptRemoteChapteredManga`、`home_video_page.dart` 的下载注册均未持久化 DTO 合集。旧合集同步仅按 bookKey 换 UID，无法识别在线漫画哈希身份或导入后标题键变化。真实 EPUB/漫画 ZIP 下载测试复现同合集 `[localUID, remoteKey]` 两行；本机另有 21 视频孤儿按远端 DTO id 精确匹配。
- **[x] ① 已修复** — 共享原子 DAO + engine 收养服务、目录/四类下载接入、v104 持久合集书键关联、在线描述符身份兼容、墓碑规范化、UI 只读持久归属/顺序。提交见本文件所在提交。
- **[x] ② 已加自动化测试** — `remote_collection_adoption_dao_test.dart`、`remote_collection_adoption_service_test.dart`、`remote_collection_identity_test.dart`；真实视频下载、EPUB/漫画包下载与在线 add、目录墓碑/手动排序 widget 回归。最终执行结果见设计文档验证记录。
- **备注**：只收养 DTO 主合集，完整同步继续管理其他关系和标签；SRT/游戏保持原边界。架构改动保留独立分支供复核。
