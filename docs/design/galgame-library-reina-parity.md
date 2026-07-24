# 游戏库对齐 ReinaManager（M1）设计契约

> 目标：把 Hibiki 的游戏库从「6 字段 JSON + 网格 + 一键启动」提升成真正的 galgame 管理器。
> 参考对象：`references/ReinaManager`（AGPL-3.0）。**只借鉴信息架构与数据模型，不复制任何
> React/Rust 源码或素材**——许可证边界见 `references/README.md`。本文件是本轮多 agent
> 并行实现的唯一契约：跨模块的表名、字段名、类名、文件路径以本文为准。

## 0. 现状与差距

现状（`hibiki/lib/src/mining/galgame_library.dart`）：`GalgameEntry` 只有 6 个字段
（id / name / exePath / workdir / coverPath / addedAt），整库序列化成偏好表单一 JSON key
`galgame_library`。没有 Drift 表、没有详情页、没有在线元数据、没有标签/筛选/排序/合集。

游玩时长现状：寄生在通用 `activity_events` 上，由 `GalHookActivityAccumulator` 按
**hook 文本行**驱动（`gal_hook_session_controller.dart` `_recordActivityLine`）。
根本缺陷：**没抓到文本 = 完全不计时**。未适配引擎、纯语音场景、hook 失败全部丢账。

## 1. 数据模型（Drift schema v55）

三张新表，定义进 `packages/hibiki_core/lib/src/database/tables.dart`，
注册进 `database.dart` 的 `@DriftDatabase(tables: [...])`。

### 1.1 `galgames`

沿用**现有 TEXT 主键**（添加时刻微秒时间戳字符串）。不改成自增 int：封面文件按
`<documents>/game_covers/<gameId>.<ext>` 命名，换主键类型要连带重命名磁盘文件，
纯粹是自找麻烦且零收益。

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | 沿用 `GalgameEntry.id`（微秒时间戳） |
| `name` | TEXT NOT NULL | 本地默认显示名（exe 文件名去扩展名）。用户覆盖走 `customDataJson.name` |
| `exePath` | TEXT NOT NULL | 注入目标绝对路径 |
| `workdir` | TEXT NOT NULL | 工作目录（默认 exe 所在目录） |
| `coverPath` | TEXT NULL | 本地封面绝对路径；null = 默认手柄图标 |
| `addedAt` | INT NOT NULL | 添加毫秒戳 |
| `playStatus` | INT NOT NULL DEFAULT 0 | 见 1.4 |
| `primarySource` | TEXT NULL | 主显示源：`bgm` / `vndb` / `mixed` / `custom`；null = 未刮削 |
| `releaseDate` | TEXT NULL | `YYYY-MM-DD`，从元数据上提，为排序建列 |
| `customDataJson` | TEXT NULL | 用户覆盖层，见 1.3 |
| `sortOrder` | INT NOT NULL DEFAULT 0 | 手动排序位（预留，M1 不做拖拽） |

### 1.2 `galgame_sources`（元数据源纵表，一游戏多源）

照抄上游最好的那个决定：加一个数据源**零 schema 变更**。

| 列 | 类型 | 说明 |
|---|---|---|
| `gameId` | TEXT | FK → `galgames.id` ON DELETE CASCADE |
| `source` | TEXT | `bgm` / `vndb`（未来 `ymgal` / `dlsite` 等直接加值，不加列） |
| `externalId` | TEXT NULL | 外部 ID（bgm subject id / `v12345`） |
| `dataJson` | TEXT NOT NULL | 该源完整快照（`GalgameMetadataDraft.toJson()`） |
| `score` | REAL NULL | 从 draft 上提，供 SQL 排序 |
| `rank` | INT NULL | 同上（仅 bgm 有） |
| `fetchedAt` | INT NOT NULL | 抓取毫秒戳 |

主键 `(gameId, source)`。

> 上游把 score/rank 做成 SQLite 生成列（`json_extract`）。我们**写入时一并落普通列**，
> 效果相同且不依赖 drift 对生成列的边角支持——少一个平台差异面。

### 1.3 `customDataJson` 结构

```jsonc
{
  "name": "用户改的显示名",
  "coverSource": "bgm",        // mixed 模式下手选封面来源
  "aliases": ["别名"],
  "summary": "用户改的简介",
  "tags": ["用户加的标签"],
  "developer": "用户改的开发商",
  "nsfw": false,
  "userRating": 8.5,           // 0-10，null = 未评分
  "userReview": "我的评价"
}
```

覆盖语义（**两种，别混**）：`name` / `summary` / `developer` / `nsfw` / `coverSource`
是**覆盖**；`aliases` / `tags` 是**并集合并**。

### 1.4 `galgame_sessions`（游玩会话事实表）

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | INT PK AUTOINCREMENT | |
| `gameId` | TEXT | FK → `galgames.id` ON DELETE CASCADE |
| `startMs` | INT | 会话起始毫秒戳 |
| `endMs` | INT | 会话结束毫秒戳 |
| `durationSeconds` | INT | 计入时长（**秒**，按 1.6 的模式决定语义） |
| `dateKey` | TEXT | `YYYY-MM-DD` 本地时区，取 `endMs` 的日期 |

索引：`(gameId, startMs DESC)` 与 `(startMs DESC)`。

> **不建统计投影表。** 上游的 `game_statistics` 是性能投影，代价是「投影与事实表
> 可能不一致」的一整类 bug（上游为此写了增量更新 + 校验失败全量重算的兜底逻辑）。
> 单机游戏库规模是几百游戏 × 几千会话，直接 `GROUP BY` 聚合即可，一次性消掉整类问题。
> 存储粒度用**秒**（上游用分钟），格式化在 UI 层做。

### 1.5 PlayStatus 枚举

数值**故意对齐 Bangumi 收藏 type**（上游这个决定很聪明，省掉一层映射）：

| 值 | 语义 |
|---|---|
| 0 | 未设置（Hibiki 新增，旧数据迁移后的默认值） |
| 1 | 想玩 |
| 2 | 玩过 |
| 3 | 在玩 |
| 4 | 搁置 |
| 5 | 弃坑 |

菜单显示顺序：想玩 → 在玩 → 玩过 → 搁置 → 弃坑。

### 1.6 计时模式

`playtime`（默认）= 只累计**前台活跃**秒数；`elapsed` = `endMs - startMs` 墙钟。
门槛 `kMinSessionSeconds = 60`，不足不落库。

### 1.7 迁移 v53 → v55

1. `createTable` 三张新表 + 建索引。
2. 读偏好表 `galgame_library` 的 JSON，逐条 `decodeGalgameLibrary` 后插入 `galgames`
   （`playStatus=0`，其余元数据列 null）。
3. **不删** `galgame_library` 这个 pref key——降级已被 `beforeOpen` 守卫挡住，
   保留它作为回滚兜底；新代码只读表，该 key 自 v55 起成为 legacy，只在本次迁移读一次。
4. 迁移幂等：`_tableExists` 守卫；fresh DB 走 `onCreate` 的 `createAll`，跳过回填。

## 2. 元数据刮削

目录：`hibiki/lib/src/mining/metadata/`

```
galgame_metadata_draft.dart      GalgameMetadataDraft（统一中间表示）+ SourceCandidate
galgame_metadata_source.dart     GalgameMetadataSource enum + 源描述 + registry
galgame_metadata_adapter.dart    GalgameMetadataAdapter 抽象接口
galgame_metadata_merge.dart      mixed 逐字段优先级合并 + custom 覆盖（纯函数）
galgame_metadata_service.dart    编排：搜索 / 按 ID 取 / 落库
adapters/bangumi_adapter.dart
adapters/vndb_adapter.dart
```

### 2.1 `GalgameMetadataDraft` 字段全集

`name` / `nameCn` / `aliases[]` / `allTitles[]` / `summary` / `tags[]` / `developer` /
`releaseDate`(YYYY-MM-DD) / `score`(0-10) / `rank` / `nsfw` / `averageHours` /
`coverUrl` / `externalId`。全部 nullable，缺就是缺。

### 2.2 Adapter 接口

```dart
abstract class GalgameMetadataAdapter {
  GalgameMetadataSource get source;
  bool validateId(String id);
  String externalUrl(String id);
  Future<GalgameMetadataDraft?> fetchById(String id);
  Future<List<SourceCandidate>> searchByName(String name, {int limit});
}
```

新增数据源 = 写一个 adapter + 在 registry 注册，搜索/合并/展示/设置 UI 全自动支持。

### 2.3 数据源

- **Bangumi**：`https://api.bgm.tv/v0`，`GET /subjects/{id}`、`POST /search/subjects`
  （`type:[4]` 限定游戏）。token 可选（R18 条目需要）。字段取 `images.large`、
  `infobox`（别名 / 开发商）、`rating.{rank,score}`、`tags[]`、`nsfw`、`date`。
  ID 校验 `^\d+$`，外链 `bgm.tv/subject/{id}`。
- **VNDB**：`https://api.vndb.org/kana`，`POST /vn`，
  `fields = id,titles{title,lang,main},aliases,image{url},released,rating,tags{name,rating,spoiler},description,developers{name},length_minutes`。
  无 ID 时 `sort:"searchrank"`。`rating` 是 0-100，落库前归一到 0-10。
  ID 校验 `^v\d+$`，外链 `vndb.org/{id}`。

两源都要**独立令牌桶限流 + 尊重 `Retry-After`**（`galgame_metadata_rate_limit.dart`）。

#### 2.3.1 与真实 API 的契约核对（2026-07-25 实测，勿凭记忆改）

适配器单测用的是自造 fixture——**fixture 猜错字段名时测试照样绿，运行时却静默刮不到东西**。
所以下面这些是打真实接口核对过的事实，改 adapter 前先看这里：

VNDB（`POST /vn`，官方文档核对）：
- `image` **必须**写成 `image{url}` 或 `image.url`；只写裸 `image` 是**错误**，服务端直接报错。
- `rating` 实际区间是 **10–100**（不是 0–100），÷10 后落在 1.0–10.0，符合我们的 0–10 语义。
- `titles` 里恰有一条 `main == true`；`released` 可能是 `YYYY` / `YYYY-MM` / `YYYY-MM-DD` / `"TBA"`。
- `tags.rating` 区间是 0（不含）到 3（含），`tags.spoiler` 是 0/1/2。
- `results` 上限 100；限流 200 请求 / 5 分钟。

Bangumi（实测 `GET /v0/subjects/935`、`POST /v0/search/subjects`）：
- 搜索响应是 `{data, limit, offset, total}`；`filter: {type: [4]}` 里 **4 = 游戏**。
- `rating` = `{rank, score, count, total}`，`score` 本身就是 0–10，不需要归一。
- `images` = `{large, common, medium, small, grid}`；搜索结果项里还可能退化成 `image` 字符串。
- **`infobox` 的 `value` 两种形状都真实存在**：`别名` 实测是 `[{v: "FSN"}, …]` 数组，
  `开发` 实测是纯字符串 `"TYPE-MOON"`。两种都必须解析，只认一种就会丢字段。
- `tags` 项是 `{name, count, total_count}`。

### 2.4 mixed 合并优先级

| 字段 | 优先级 |
|---|---|
| name / nameCn | bgm → vndb |
| coverUrl | `customData.coverSource` 手选优先，否则 bgm → vndb |
| summary | bgm → vndb |
| developer | **vndb → bgm** |
| tags / aliases / allTitles | bgm ∪ vndb（去重，保序） |
| score | bgm ‖ vndb |
| rank | 仅 bgm |
| averageHours | 仅 vndb |
| releaseDate | bgm → vndb |

合并后叠加 `customDataJson` 覆盖层（语义见 1.3）。整个合并必须是**纯函数**，可单测。

### 2.5 失败与多结果交互

- 多结果 → 候选列表让用户选（`GalgameSourcePickerDialog`），选中后 `fetchById` 补全。
- 输入即 ID（`validateId` 命中）→ 直接 `fetchById`，跳过搜索。
- mixed 下部分源失败 → 降级为「该源为空」，不整体失败；**全部源失败**才报错。
- 网络失败必须给可读文案，不吞异常。

## 3. 游玩计时（Windows）

文件：`hibiki/lib/src/mining/galgame_play_tracker.dart`

脱离 hook 文本，改为**前台窗口 + 候选进程组**（上游 `monitor/windows.rs` 的思路）：

- 200ms tick：`GetForegroundWindow` → `GetWindowThreadProcessId` 拿前台 PID。
- 1s tick：只读共享状态累加秒数；`OpenProcess` + `GetExitCodeProcess`
  （`STILL_ACTIVE == 259`）判活。
- **候选进程组**：启动 3s 后 `CreateToolhelp32Snapshot` 枚举全部进程，凡 exe 路径在
  **游戏目录下**的都进候选集——解决 Launcher → 本体切换导致的丢账。
- **逃逸检测**：前台 PID 不在候选集时，查其 exe 路径是否在游戏目录下；路径比较必须
  按**路径组件**（原始 + `canonicalize` 双路径、忽略大小写），防 `C:\Games\Game`
  误匹配 `C:\Games\Game2`。
- 主进程连续失活 3 次 → 重扫目录切新 PID；扫不到则结束会话。
- 会话结束：`durationSeconds >= 60` 才写 `galgame_sessions`。

用现有 `win32` 依赖，不引新包。非 Windows 平台整体 no-op（galgame hook 本来就只做
Windows，见根 `CLAUDE.md`「Galgame Hook 硬规则」）。

### 3.1 与现有 activity_events 的关系（**必须处理，否则双计**）

现状：`GalHookActivityAccumulator` 按 hook 文本行写 `activity_events`
（`durationMs` + `charsDelta`）。新 tracker 若也写时长 → **同一次游玩被计两遍**。

约定：
- **时长真相源 = tracker**。tracker 在会话结束时写一条 `activity_events`
  （`eventType: 'game'`, `mediaType: 'game'`, `durationMs` = 本次会话时长）。
- `GalHookActivityAccumulator` **不再写 `durationMs`**，只保留 `charsDelta`
  （hook 文本字符数仍然有价值，喂首页「今日字符数」）。
- 首页 dashboard 的读取端（`home_dashboard_page.dart` `getActivityDailyTotals`）
  按现有语义继续工作——时长来自 tracker 的行，字符来自 accumulator 的行，
  两者聚合到同一天不冲突。
- 顺带修掉 `activity_event_types.dart:17` 与 `tables.dart:208` 那两条
  「本轮仅预留、无写入方」的**过期注释**（早就有写入方了）。

## 4. UI

### 4.1 游戏库页（改造 `games_library_page.dart`）

- 顶部工具条：搜索框 + 排序/筛选入口。
- **排序**：添加时间 / 发行日 / 最后游玩 / 站点评分 / 我的评分 / 名称 × 升降。
- **筛选**：PlayStatus（全部 + 5 态）/ 本地·在线 / 标签多选 / NSFW 隐藏。
- **搜索**：对 name / nameCn / aliases / allTitles 做归一化子串匹配
  （上游用 Fuse.js + 拼音；Dart 侧 M1 先做归一化子串，**不引新依赖**）。
- 卡片：3:4 封面 + 标题；可选「排序字段浮层」（显示当前排序维度的值）。
- 卡片点击行为沿用现状（启动游戏）；**长按 / 右键 → 详情页**，避免破坏现有肌肉记忆。

### 4.2 详情页（新增 `galgame_detail_page.dart`）

头部常驻：封面大图、显示名、开发商、站点评分 + 我的评分、标签 chips、外链、启动按钮。

3 个 tab：
1. **统计**：累计时长 / 游玩次数 / 今日时长 / 最后游玩 四个 KPI + 按月每日柱状图 +
   会话流水列表（可删单条、可手动补记录）。
2. **简介**：summary、别名、all_titles、发行日、预计时长。
3. **编辑**：改显示名/封面/简介/标签/开发商/日期/NSFW/我的评分/我的评价；
   改 exe 路径与工作目录；**换数据源 / 重新刮削**（搜索模式或手填 ID，先预览再应用）。

## 5. 不在 M1 范围

存档 7z 备份、合集（复用现有 collections 而非新建，留 M2）、拖拽排序、
Locale Emulator / Magpie 联动、云端收藏双向同步、拼音模糊搜索、目录扫描批量导入、
YMGal / Kungal / DLsite / ErogameScape 四个源。

## 6. 验证要求

- 纯函数（合并优先级、路径归一、搜索匹配、draft 解析）必须有单测。
- 迁移 v53 → v55 必须有测试：建旧库 → 写 pref JSON → 升级 → 断言表内数据一致。
- 全量 `flutter analyze`（含 test 目录）零 warning。
- 路径相关测试一律用 `p.join` 构造，**禁止硬编码 `C:\`**——Linux CI 上 basename
  不会按 `\` 拆分（已被 #370 坑过一次，见 `16b981c63`）。
