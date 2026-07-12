# 排序交互重设计（替代已删除的整理排序页）

> 状态：**设计稿，待用户拍板**（三个决策点见 §5）。拍板后按 §6 任务表实现。
> 分支：`worktree-unified-collections-plan`（PR#41 延续）。
> 前情：旧整理排序页两次被否（「砍掉重做」→「整个砍掉，做的太烂了」），已于
> `16b5adc75` 整页删除（-3715 行）。本文档是接续用户「设计新排序交互吧」的产出。

## 1. 旧页面为什么烂（失败教训）

旧整理页把排序做成了一个**脱离上下文的全屏编辑模式**：

1. 所有卡缩成可拖小块，真实布局（封面大小、合集行、进度）全部消失——排完出来才知道效果。
2. 分组、移出、排序三种操作混在同一页，拖拽既是「移动位置」又是「拖进组」，语义打架。
3. 它持久化 `ShelfEntries.sortOrder`，但详情页/播放器读 `MediaCollectionItems.sortIndex`——
   同一合集排完后在库页、详情页、播放器三处顺序不一致（结构性缺陷，不是 bug）。

结论：**「手动拖拽编辑模式」这个概念本身就是错的**。Jellyfin/Netflix/Plex 没有一个提供
库级手动摆位——它们提供**排序方式**。手动排序只在一个地方真正有意义：**合集内部的
播放/阅读顺序**，而那里应该就地排，不需要独立页面。

## 2. 现状排序真相（代码考古，2026-07-12）

| 位置 | 排序依据 | 问题 |
|---|---|---|
| 书架散卡+合集行序 | `ShelfEntries.sortOrder` asc → 历史序（最近访问） | sortOrder 已无任何写入方=**死权重**（旧拖拽残值仍在生效且再也改不了） |
| 视频页散卡+合集行序 | `ShelfEntries.sortOrder` asc → `listForShelf` 原序（≈导入序） | 同上；且无法按最近观看/名称切换 |
| 库页合集行**内**成员序 | `ShelfEntries.sortOrder` → importedAt desc（`groupByCollections` 组内序） | 与详情页/播放器**不同源** |
| 合集详情页 / 播放器换集 | `MediaCollectionItems.sortIndex`（加入顺序，`getCollectionItems`） | 顺序错了（如手动攒的播放列表）**无任何途径修改** |
| `reorderCollectionItems` / `updateMediaCollectionSortOrder` DAO | 事务回写，能力完好 | **零 UI 调用方**（随整理页删除成孤儿） |

核心判断：真问题有两个——①播放/阅读顺序错了没法修；②库页不能按最近/名称/导入切换视图序。
「库级手动摆位」是伪需求（旧页面存在的唯一理由），不再提供。

## 3. 新设计：三层，零模式页

### 层次 A：库页「排序方式」菜单（书架 + 视频页统一）

**入口**：标签栏动作槽（原「整理」swap_vert 的位置）加一个 `Icons.sort` 图标按钮，
点开单选菜单（三项，当前项打勾）。桌面 MenuAnchor 锚定弹出、移动端 bottom sheet，
均为焦点可达（手柄/键盘 Tab+Enter）。

```text
┌──────────────────────────────────────────────────────┐
│ [标签A] [标签B] [标签C]        ⚙  ☑  ⇅sort           │ ← 标签栏
└──────────────────────────────────────┬───────────────┘
                                       │ ▼ 点开
                              ┌────────┴────────┐
                              │ ✓ 最近观看      │  (书架侧文案=最近阅读)
                              │   名称          │
                              │   导入时间      │
                              └─────────────────┘
```

**三种模式**（两页共用同一 enum，只差 recent 的语义/文案）：

| 模式 | 书架 | 视频页 |
|---|---|---|
| `recent`（默认） | 最近阅读 = 现状历史序（**零行为变化**） | 最近观看 = watch-stats `_watchAtByUid` 倒序，无记录退导入时间倒序 |
| `title` | 书名 natural 排序（卷1<卷2<卷10） | 名称 natural 排序 |
| `imported` | `importedAt` 倒序（epub/srt 两表均有该列） | `importedAt` 倒序 |

**合集行的排序键 = 成员聚合**：`recent` 取成员最近值 max、`title` 取合集名、
`imported` 取成员 importedAt max。散卡与合集行照旧同层混排，只换比较键。

**持久化**：`preferences` 表两 key（`shelf_sort_mode` / `video_sort_mode`），
沿 `PreferencesRepository` 现有 typed-wrapper 模式；切换即时重排、跨启动记住。

**死权重清理（好品味：一个概念换三层隐式规则）**：`ShelfEntries.sortOrder` 与
`MediaCollections.sortOrder` 的读取点全部删除（`groupByCollections` 的
`itemSortOrder` / `groupSortOrder` 参数随之简化掉），**列保留**不动 schema
（备份/远端兼容，Never break userspace 的数据面）。排序序完全由 sort mode 推导，
无隐藏状态。

### 层次 B：合集详情页就地排序（真正需要手动的地方）

**B1. 视频合集/播放列表详情页**（`media_collection_detail_page.dart`，已是集列表）：

1. **一键整理**（覆盖 95% 场景）：AppBar 加「排序」菜单——「按名称」「按导入时间」，
   选中即按该键重排全表并 `reorderCollectionItems` 一次落盘。乱序的手攒播放列表
   一键回文件名序。
2. **拖拽精修**：`ListView.builder` → `ReorderableListView.builder`
   （`buildDefaultDragHandles: false`）；每行行尾加拖柄
   `ReorderableDragStartListener(child: Icon(Icons.drag_handle))`（桌面鼠标即拖），
   移动端整行 `ReorderableDelayedDragStartListener`（长按拖）。`onReorder` 内存
   move 后同样 `reorderCollectionItems` 落盘。
3. 排完**播放器换集、继续看、库页合集行立即同序**（都读 sortIndex，见层次 C）。

```text
┌ 合集：某番剧 ──────────────── 重命名 删除 ⇅排序 ┐
│ [▶ 继续播放 第3集]                                │
│  1  [缩略图] 第1集………………………… ✓   ⊖  ≡        │ ← ≡ = 拖柄
│  2  [缩略图] 第2集………………………… ✓   ⊖  ≡        │
│  3  [缩略图] 第3集………………………… ▶   ⊖  ≡        │
└──────────────────────────────────────────────────┘
```

**B2. 书籍合集详情页**（`media_collection_grid_detail_page.dart`，封面网格）：
v1 **只加**同款「排序」一键菜单（按名称/按导入时间，写穿 sortIndex），
**不做网格拖拽**——卷序=名称 natural 序几乎恒等于正确阅读序；framework 无
reorderable grid，自研的那个刚因烂被删，不复活（决策点②）。

### 层次 C：成员序单一真相源（顺手根治结构缺陷）

库页合集行的**组内序**从「`ShelfEntries.sortOrder` → importedAt desc」改为读
`MediaCollectionItems.sortIndex`（页面预取一次全量成员行建
`'<mediaType>|<entryKey>' → sortIndex` 映射喂给 `groupByCollections`）。此后：

**库页行内顺序 ≡ 详情页顺序 ≡ 播放器换集顺序 ≡ sortIndex**，一处落盘三处生效，
「同一合集三处三种顺序」这个特殊情况被消灭。

## 4. 不做的事（明确拒绝）

- **库级手动摆位**：不做。伪需求，旧页面的失败根源。
- **合集卡置顶/pin**：不做（YAGNI）。合集位置由排序模式的聚合键决定。
- **书网格拖拽**：v1 不做（决策点②），真实需求出现再评估（列表形态或上移/下移）。
- **新 schema**：零迁移。`sortIndex` / 两个死权重列 / preferences 全是既有结构。

## 5. 待用户拍板（三点，均已给推荐）

1. **视频页默认排序**：推荐默认 `recent`（最近观看）——与顶部「继续观看 hero」语义
   一致、Jellyfin 同款；但这改变现状（现状≈导入序，一键可切回「导入时间」）。
   若要绝对零变化则默认 `imported`。
2. **书合集详情不做拖拽**（只一键按名称/导入重排）：推荐接受；视频详情有完整拖拽。
3. **废弃旧手动权重**：以前整理页拖出来的顺序残值（`ShelfEntries.sortOrder` /
   `MediaCollections.sortOrder`）不再参与排序（数据保留只删读取点）。推荐接受——
   该顺序本来就再也改不了。

## 6. 实现任务表（拍板后执行）

| # | 任务 | 文件 | 验证 |
|---|---|---|---|
| 1 | 纯函数层：`ShelfSortMode` enum + `naturalCompare(String,String)`（数字段按数值比较）+ 各模式排序键推导 | 新 `hibiki/lib/src/media/collections/shelf_sort.dart` | 新单测（natural 序、聚合键、稳定 tie-break） |
| 2 | 偏好：`shelfSortMode` / `videoSortMode` typed wrappers | `preferences_repository.dart` | 单测沿现有 prefs 测试模式 |
| 3 | i18n：`sort_by`/`sort_recent_read`/`sort_recent_watched`/`sort_title`/`sort_imported`（i18n_sync.dart + slang） | 17 json + strings.g.dart | `dart run slang` 通过 |
| 4 | 标签栏 sort 入口 + 单选菜单（复用 `_tagBarAction` + MenuAnchor/GamepadMenuDropdown 模式，焦点可达） | `tag_filter_bar.dart` + 两页接线 | widget 测试：切换→网格顺序变化 |
| 5 | 视频页接线：删 `_videoOrder` 死权重读取，按 mode 排序（recent 复用 `_watchAtByUid`） | `home_video_page.dart` | 既有页面测试 + 新排序断言 |
| 6 | 书架接线：同上（imported 需预取 epub/srt `importedAt` 映射） | `reader_hibiki_history_page.dart` | 同上 |
| 7 | 层次 C：`groupByCollections` 简化（删 itemSortOrder/groupSortOrder，入参改成员 sortIndex 映射 + 页面级排序键） | `collection_grouping.dart` + 两页 | 更新 `collection_grouping` 单测 |
| 8 | 视频详情页：ReorderableListView + 拖柄 + onReorder 落盘 + 一键排序菜单 | `media_collection_detail_page.dart` | widget 测试：拖拽/一键→`getCollectionItems` 序变化（真写穿 DB） |
| 9 | 书详情页：一键排序菜单 | `media_collection_grid_detail_page.dart` | 同上 |
| 10 | 守卫更新：架构守卫加「库页不读 ShelfEntries.sortOrder」不变量 | `unified_collections_architecture_guard_test.dart` | 全量 `flutter analyze` + `flutter test` |

铁律边界：拖拽手感/菜单视觉属布局交互改动，落地后需真机复测（Windows 桌面 +
Android 均有真机通道）；离屏只能验到「写穿 DB + 顺序断言」。
