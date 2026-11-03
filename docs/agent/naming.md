# 命名术语表（2026-07 定案，新代码遵守）

从根 `CLAUDE.md` 拆出（2026-11-03）。

同概念一词。存量持久化名（DB 列/偏好键/磁盘目录/wire key）**冻结不追改**，但新代码/新 UI 不再产生淘汰词；详见 `docs/` 下命名统一审计与守卫测试。

| 概念 | 唯一词 | 淘汰词（新代码禁用） |
|---|---|---|
| 媒体配图 | `cover` / 封面 | poster、thumbnail（书岛旧持久化名冻结） |
| 库页（书/视频/游戏页面统称） | library page / 中文按域「书架/媒体库」 | shelf 用作页面名；中文「书库」 |
| 条目排序/归属映射层 | `shelf`（`ShelfEntries` 域） | — |
| 扫描根 | `source library`（`media/source_library/`） | 裸 source |
| 最近打开流 | `history`（仅此一义） | history 用作书架页面名 |
| 首页面板 | `dashboard` | — |
| 续播三层 | 选条目 `continue*` / 定起点 `resolve*ResumePoint` / 落地执行 `restoreTo*` | 三层动词混用 |
| torrent 恢复数据 | `fastResume*`（对齐 qBittorrent） | 裸 resume |
| 互联对端 | 已配对对端 `peer` / 提供库角色 `host` / 对端数据 DTO `Remote*` / 未配对发现 `device`；子系统名 `Interconnect*` | 混用；`FushiClient*` 作类名前缀 |
| 备份操作 | 顶层 `createBackup`/`restoreBackup`；内部子步骤 `reapply*`；export/import 只留给单资产 | 内部子步骤叫 restore* |
| 时刻列 | `<名>At`（int 毫秒，无 Ms 后缀） | `Ms` 后缀用于时刻（仅时长/偏移可用） |
| 墓碑删除时刻 | `deletedAt` | removedAt |
| 媒体种类值域 | 各域独立枚举（`MediaKind`/`ActivityMediaKind`/`StatSourceKind`/`ProfileMediaKind`/`SyncTombstoneKind`/`SourceLibraryKind`/`SentenceSourceKind`），跨域换算走 `media_kind_mappings.dart`，禁 UI 层裸字符串比较/bool 降维 | — |
| 搜索匹配 | `matchesMediaSearch`/`filterByMediaSearch`（统一归一化） | 裸 `toLowerCase().contains` 做用户可见搜索 |
| 重复条目**处置策略** | 单参 `DuplicatePolicy` 三态：交互式单条 `.ask(cb)` / 批量后台 `.skip()` / 程序化留副本 `.suffix()`。三种差异**有意**（交互预算不同），不要再往一起合，但必须显式声明 | `bool skipIfExists` + `DuplicateTitleCallback?` 两参编码三态；`onDuplicateTitle` 作参数名 |
| 重复**判据**（这东西是否已在库） | `isDuplicate*` / `filterOutDuplicate*` | `isVideoPathReferenced`、`filterDroppedGameExes` |
| 用户对重复的选择 | `DuplicateChoice{suffix, cancel}`（与策略词同形） | `DuplicateTitleResolution{addSuffix, cancel}` |
| i18n key | `<域>_<子域名词>_<动作/状态>`（动词在尾）+ 英文 sentence case；改名必须 `i18n_sync --rename` | 手改 json；新增 `games_`/`ttu_` 前缀 key |
