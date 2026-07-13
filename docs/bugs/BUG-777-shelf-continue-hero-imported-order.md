## BUG-777 · 继续阅读hero与书架最近阅读按导入序选书而非最近阅读序
- **报告**：2026-07-12（用户：「这个继续阅读显示不对，我明明刚刚看的是另一本书。并且好像也没同步远端」，PR#41 真机测试反馈）
- **真实性**：✅ 真 bug。根因链：
  - `packages/hibiki_core/lib/src/database/database.dart:3106` — `getAllEpubBooks()` 按 `importedAt DESC` 排序，这是 `hibikiBooksProvider` 的唯一顺序来源；
  - `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:640-648` — 继续阅读 hero 取「列表里第一本 0<position<duration 的书」，注释声称「provider 即最近访问序」，**前提为假**——实际选中的是「最近**导入**的在读书」，刚读过的老书永远排在后面；
  - 同页 `_shelfGroupSortKey`（原 `recentScore: -it.payload.seq`）— 书架「最近阅读」排序模式把 provider 下标当历史名次，实际序 = SRT 表序 + EPUB 导入序，与「最近阅读」无关（排序交互重设计 2026-07-12 的「recent=现状历史序零变化」承诺基于同一假前提）。
  - 真「最后阅读时间」一直存在：`reader_positions.updatedAt`（`ReaderPositionRepository.save` 每次落位置都刷新；EPUB/SRT 同走 bookKey，BUG-723 已确认同源），只是从没人读它。
- **[x] ① 已修复** — `getAllReaderPositions()` 批量 DAO + `bookLastReadAtProvider`（关书 `onSourceExit` 与 `hibikiBooksProvider` 同点 invalidate，永不陈旧）；hero 改选「lastReadAt 最大的在读书」；书架「最近阅读」recentScore 改 `lastReadAt ?? importedAt`（没读过的书按导入时间融入，与视频页 watch-stats 语义镜像）；`_ShelfBookSlot.seq` 假名次字段删除。提交 a16aec742。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/shelf_recent_read_order_test.dart`（hero 纯选择器：刚读的老书赢过更晚导入的书；真 DB provider：updatedAt 映射 + invalidate 拿到重读新时间戳）+ `unified_collections_architecture_guard_test.dart` 源码守卫（页面必须消费 lastReadAt 映射、「没读过退 importedAt」表达式、seq 假名次零残留、关书同点失效）。提交 a16aec742。
- **备注**：用户同报「好像也没同步远端」有两个候选解释，均非本修复范围：
  1. **hero 幻象**：远端设备即使同步成功，hero 一样按导入序选错书，让人误判「没同步」——本修复后应重新观察；
  2. **自动同步未开**：`triggerAutoSyncAfterClose` / app-open 全量同步都有 `isAutoSyncEnabled()` 门（默认 false），未开启时只有手动「立即同步」会推进度。请用户核对 设置→同步→自动同步 开关；若开着仍不同步再按真 bug 追（`sync_auto_trigger.dart` 冷却 5 分钟仅 app-open 路径，关书路径无冷却）。
  3. hero 仍只考虑 EPUB（SRT 卡进度维度不同，现状边界，非本 bug 引入）。
