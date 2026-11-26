## BUG-5457 · 删合集 / 游戏后「同一作品」留下标题是一串 id 的未入库死卡，灰卡背后还垫着一块灰板
- **报告**：2026-11-25（用户：漫画详情「同一作品」里第一张动画卡标题是「13」、副行「同一作品 · 未入库」，卡片背后连组名一起压着一块灰色方块）
- **真实性**：✅ 真 bug，两个独立根因（根因 1 的合集部分与 [BUG-5462](BUG-5462-deleted-collection-links-dangling.md) 是同一个 bug，两边分头修、合流时收成一套实现）：
  1. **死连接**：合集 / 游戏端点的键是本机 id（`media_collections.id` AUTOINCREMENT 不复用；游戏重新入库拿新 id），删了就永不再出现。删除路径不清 `media_links`——`deleteMediaCollection`（`packages/fushi_core/lib/src/database/database_library.part.dart` `deleteMediaCollection`）、删视频移空自删合集（同文件 `removeEntriesFromAllCollections`）、同步应用端 `deleteMediaCollectionRaw`、`deleteGalgame`（`database_statistics.part.dart`）都只删本表，连接留着，`resolveMediaLinkEntry`（`fushi/lib/src/media/links/media_link_entries.dart:137-142`）找不到合集就拿原始 id 当标题。合集合并（`collection_merge.dart` `mergeMediaCollectionsInto`）也把被并掉合集的连接留在死 id 上，而不是跟成员一起搬到目标。同步 / 备份合并落合集 / 游戏端点前本就先换算成本机 id、本机没有就跳过，所以「端点必须本机存在」本来就是全局约定，只有删除路径漏了。
  2. **灰板**：「未入库」灰卡用 `ColorFilter.mode(Colors.grey, BlendMode.saturation)` 去饱和（`fushi/lib/src/media/links/media_links_section.dart` `_buildCard`）。混合模式滤镜对完全透明的像素也生效（结果 = 滤镜色），封面材质 `BakedSurface` 四周给投影留的透明外扩区（`kShelfMaterialShadowExtent` 40/32/40/56）整块被涂成灰色，再乘 0.45 不透明度，就是截图里比封面大一圈、压住组名和副行的灰方块（尺寸与外扩区逐像素吻合）。
- **[x] ① 已修复** —
  - DB 内核（`database_media_links.part.dart`）：`purgeMediaLinksForEndpoint`（端点被删：物理删其全部连接含墓碑，不写否决）、`retargetMediaLinks`（端点被并：改挂到目标，自环丢弃，撞身份按跨端 LWW 内核取胜者）、`purgeDanglingMediaLinks`（清存量死行）。
  - 删除路径同事务清理：删合集的全部路径（用户删除、移空自删、删条目连带清空、`deleteMediaCollectionRaw`）统一经 BUG-5462 的 `_dropMediaCollectionRow` 删掉以合集为端点的连接；`deleteMediaCollection` 新增 `linksMovedTo`（合并时先 `retargetMediaLinks` 改挂、再删合集行，顺序不能反）；`deleteGalgame` 走 `purgeMediaLinksForEndpoint`；`mergeMediaCollectionsInto` 传 `linksMovedTo: targetId`；备份导出 / 覆盖导入裁掉游戏或合集后同样清死行。AniDB 拆分合集（一拆多部作品）不改挂、按删除处理——原连接对应的是整组，没有唯一去向。
  - schema v181（数据迁移，表结构不变）：清掉存量死行，幂等。
  - 灰卡改用 Rec.709 亮度颜色矩阵 `mediaLinkMissingCoverFilter`：只改 RGB、alpha 原样，透明处仍透明。
- **[x] ② 已加自动化测试** — `fushi/test/database/media_link_dangling_endpoint_test.dart`（每条删除路径 + 合并改挂 / 去重 / LWW + v180→v181 迁移幂等）；`fushi/test/media/links/media_links_section_test.dart`（灰卡用新滤镜；读像素：新滤镜透明外扩区 alpha 0，旧滤镜对照涂成灰）。
- **备注**：AI 整理器合并后撤销：合并快照同时记下胜方受改挂影响的连接原状，撤销时还原（见合流语义修复提交）。`media_link_entries.dart` 对合集 / 游戏死端点仍拿 id 当标题——修复后这类端点不再存在（删除即清、迁移清存量、同步 / 备份落地前换算），不另加显示层兜底。书 / 视频 / 音乐端点键跨端稳定，本机没有时照旧是「未入库」灰卡（设计如此）。
