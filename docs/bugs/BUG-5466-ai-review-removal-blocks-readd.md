## BUG-5466 · AI 管库拆散 / 挪走的集，用户再「加入媒体库」也归不回合集
- **报告**：2026-11-24（用户：Jellyfin「加入媒体库」的整部剧在首页「最近添加」里逐集显示；再点「加入媒体库」也恢复不了）。从 PR #4424 拆出（维护者要求：清 AI 移出墓碑单独成 PR、不带 `pinMember`，整理记录每次加入只读一次）。
- **真实性**：✅ 真 bug（按用户本机数据复核）。入库后的「导入后 AI 助手复查库」对剧名 playlist 执行了 `dissolve`：每集一条成员墓碑、合集移空自删。AI 的移出经 `removeFromCollectionAutomatically`（`packages/fushi_core/lib/src/database/database_library.part.dart:1866`）写下的成员墓碑与用户亲手移出的一模一样；用户亲手「加入媒体库」时 `adoptRemoteCollectionMember`（同文件 `:1380`，`userIntent: true`）只清合集级墓碑，成员墓碑照拦（BUG-5016 的语义）——AI 的判断压过了用户的显式再加入，集永远散着，只能去整理记录里撤销那次运行。
- **[x] ① 已修复** —
  - `adoptRemoteCollectionMember` 加 `organizerRemovedKeys`：只在 `userIntent` 时生效，只看本条目自己的键（远端键 / 本机键），清掉**本机 AI 整理移出**留下的成员墓碑；用户自己移出的照常拦，被动收养（探针 / 目录刷新 / 同步）不清。DAO 不解析整理记录载荷。
  - 引擎 `OrganizerRemovals`（`packages/fushi_engine/lib/media/collections/library_organize/library_organize_apply.dart`）按设备本地整理记录里未撤销的 `evict`（来处 = 记录所在合集）与 `move`（来处 = `payload.from`）认出 AI 的移出，按（合集名, 类型, 媒体类型）索引。
  - `RemoteCollectionAdoptionService.adoptVideos`：一次「加入媒体库」的全部集一起收养，整理记录只读一次；媒体服务器与在线视频源的 `addMissing` 改走它。单集入口（下载入作品等）只读那一个合集的记录。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/sync/remote_collection_adoption_organizer_test.dart`（真实 dissolve 变更集：被动收养不放回且不读整理记录、用户再加入放回且整部剧只读一次整理记录；用户自己移出的那一集仍不放回；`move` 的来处合集再加入放回、已撤销的 move 不算）；`fushi/test/database/remote_collection_adoption_dao_test.dart`「BUG-5466 organizerRemovedKeys」组（只在 userIntent 时清、只清列出的键）。
- **备注**：整理记录设备本地、不同步——别的设备上 AI 移出、同步过来的成员墓碑本机认不出，用户再加入仍被拦。「来源断言的剧归属钉住、AI 不再拆散」那一半留在 PR #4424（draft），等维护者拍板。
