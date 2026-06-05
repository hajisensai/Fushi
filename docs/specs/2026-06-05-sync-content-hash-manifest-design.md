# 同步内容 hash manifest 设计

- 日期：2026-06-05
- 状态：设计已确认，待写实现计划
- 涉及模块：`hibiki/lib/src/sync/`

## 1. 背景与问题

当前大资产（书 epub / 词典包 / 有声书包 / 本地音频库）的同步是 **"按名字存在即跳过" 的 additive union**：

- `sync_orchestrator.dart` 各 `sync*` 方法列远端目录拿名字，与本地集合求差集，只 push 本地独有、pull 远端独有；**"两边同名都有" 直接跳过**。
- 判据只有名字，**不比时间戳、不比大小、不比内容**。`DriveFile` / `AssetEntry` 现在只带 `id / name / sizeBytes`，列目录请求里连 Drive 原生的 `md5Checksum` 都没要。

由此两个真实缺口：

1. **传输损坏/截断无法发现**：远端文件传一半或损坏，下次同步仍因"同名存在"被跳过，或被当好文件拉下来用。
2. **同名内容更新不传播**：在 A 设备替换了同名书/词典的内容，B 设备永远停在旧版本。

直接依赖各后端原生 hash 能力不可行——能力不对称：

| 后端 | 列目录能否白拿内容 hash |
|---|---|
| Google Drive / Dropbox / OneDrive | 能（`md5Checksum` / `content_hash` / `file.hashes`） |
| WebDAV / FTP / SFTP / 自建局域网 server | 不能（标准协议无内容 hash） |

依赖它会在代码里塞满 per-backend 特例。

## 2. 目标与非目标

### 目标

- **G1（防损坏 = 完整性保证）**：下载完成后用 manifest 里的 md5 校验文件，不符则拒绝落地、记错误，绝不污染本地。**这是唯一的数据完整性保证，与 mtime 无关**——无论方向怎么判，落地的数据一定完整未损坏。
- **G2（内容更新传播 = 尽力而为的最新性）**：同名但内容不同的大资产，按"修改时间新的胜"自动覆盖，覆盖前先落临时文件校验、通过才原子替换。**mtime 是依赖设备时钟的启发式**：时钟回拨等极端情况下可能判错方向（拿到较旧但**仍完整**的版本），但绝不会损坏数据。要 100% "永远最新" 只能弹窗让人选，已与用户确认选 A（自动、不打扰），接受此取舍。
- **G3（全后端一致）**：核心机制不依赖任一后端的原生 hash 能力；原生 hash 仅作为可选的上传端加速校验。
- **G4（云端完整性）**：见 §7，四层防线保证坏数据不会被任何设备用上。

### 非目标

- 不做块级/增量同步（rsync 式 delta）；整文件粒度。
- 不为大文件内容冲突做交互式弹窗（A：mtime 自动胜，已与用户确认）。
- 不改小 JSON（progress / stats / 有声书位置）的**时间戳同步机制**本身（仅删除其开关，见 §8）。
- 不传播删除（保持现有 union 不删语义）。

## 3. 核心机制：我们自己拥有的 sidecar manifest

因为**上传路径是我们自己控制的**，在写资产时把 md5 一并算好、写进同目录的一个小 JSON。manifest 就是一个普通小文件，用每个后端**已实现**的 `putJsonAsset` / `getJsonAsset` 读写——所以**零后端改动**，逻辑全部待在编排器层 + 一个新 helper。

### 3.1 manifest 格式

每个大资产旁写一个 `<assetName>.manifest.json`（与资产同命名空间）：

```json
{ "v": 1, "md5": "<32位小写hex>", "size": 12345678, "mtime": 1733400000000 }
```

- `v`：schema 版本，便于演进。
- `md5`：资产文件内容的 md5（hex）。
- `size`：字节数（md5 之前的廉价预筛 + 截断检测）。
- `mtime`：**上传方写入时的本地资产文件修改时间戳（毫秒）**，G2 的"谁更新"判据。是"资产被生成/导出的时间"，不是文件传到云端的时间。

> 为什么不用 `AssetEntry.sizeBytes` 或后端 mtime：WebDAV PROPFIND 不返回大小、各后端 mtime 语义不一，不可移植。manifest 把这三个值变成我们自己写自己读的数据，消除后端差异。

### 3.2 manifest 命名约定

`<assetName>.manifest.json`（如 `物書堂.hibikidict.manifest.json`、`audiobook.hibikiaudio.manifest.json`、`content.epub.manifest.json`）。manifest 自身在 union 名字集合里**排除**（`isReservedSyncFolderName` 新增 `.manifest.json` 后缀过滤），不能被当成待同步资产。

## 4. 本地 md5 计算与缓存

新增 helper `hibiki/lib/src/sync/sync_content_hash.dart`：

```dart
/// 流式计算文件 md5（不整文件进内存），返回小写 hex。
Future<String> computeFileMd5(File file);

/// 带缓存的 md5：缓存键 (绝对路径, size, mtimeMs)；命中直接返回，
/// 未命中或 size/mtime 变化时重算并写缓存。
Future<String> cachedFileMd5(File file, ContentHashCache cache);
```

- 实现用 `package:crypto` 的 `md5.bind(file.openRead())`，瓶颈是**把整个文件读一遍的磁盘 IO**（小文件微秒级，但大资产可达数百 MB，手机闪存上是数百 ms 级），不是 CPU。
- **临时文件（刚下载/刚导出）直接 `computeFileMd5`，无需缓存**——本来就在手上必须读。
- **本地已存在的大资产用 `cachedFileMd5`**：内容更新判定（§6）要比对它们 vs 远端，若每次自动同步都重读所有本地大文件做 md5，对大书库是数 GB 重复 IO。缓存键含 size+mtime，文件一改自然失效；本质是"记住上次算的值，文件没动就不重读"。
- 缓存落 Drift（新窄表 `content_hash_cache(path, size, mtime, md5)` 或复用 `preferences`，实现计划定）。

## 5. 改动触点（全部在编排器层）

所有 push/pull 都经过 `sync_orchestrator.dart` 的统一接缝（`_backend.putAsset` / `_backend.getAsset`），manifest 收口成私有 helper：

```dart
/// push 资产 → 成功后写 manifest（md5/size/mtime） → 若后端支持原生 hash，回比一次。
Future<void> _putAssetWithManifest(String ns, String name, File file, {onProgress});

/// pull：下载到临时文件 → 读远端 manifest → 校验 size+md5 → 通过才返回 true。
/// 校验失败删临时文件、记 error，绝不交给上层 import。远端无 manifest（旧数据）降级跳过校验。
Future<bool> _getAssetVerified(AssetEntry asset, String manifestId, File tmp, {onProgress});
```

涉及的同步路径：书 epub 的 push / pull（`sync_orchestrator.importRemoteBooks` + `sync_manager` 中书内容导入/导出触点，计划阶段逐一定位）、`syncDictionaries`、`syncLocalAudioPackages`、`syncAudiobookPackages`。规则统一：所有 `putAsset` 调用点换 `_putAssetWithManifest`，所有 `getAsset` 换 `_getAssetVerified`。

## 6. 同步决策（单一交付，含内容更新传播）

把四个 `sync*` 的"两边都有 → 跳过"改为：

```text
远端有、本地无 → pull（下载→校验→import）
本地有、远端无 → push（导出→上传→写 manifest）
两边同名都有：
  读远端 manifest.md5 与本地 cachedFileMd5：
    相同        → 跳过（内容一致，比"同名即跳过"更可信）
    不同：
      远端 mtime 更新 → pull 到临时文件 → md5 校验 → 通过才【原子重导入】覆盖本地
      本地 mtime 更新 → 重新导出 → putAsset + 覆盖远端 manifest
      mtime 相等       → 确定性 tiebreak：md5 字典序大的一方胜（按对应方向覆盖）
```

> **为什么不是"平手跳过"**：跳过会让两边永远不一致。`mtime 相等且 md5 不同` 现实中近乎不可能，这里只需一个**确定性、无状态、两端算出同一答案**的 tiebreak（md5 字典序）保证系统**必然收敛**，而不是引入一个 divergent 特例。

"原子重导入覆盖本地"按资产类型分别落地（每类一个子任务 + 测试）：

- **词典**：导入到临时资源目录 → 成功后替换正式目录 + 更新 DB 行；失败回滚，不破坏现有词典。
- **有声书包**：重新 import 覆盖该 book 的 audio DB（复用已有 `bookUidOverride` 重键路径）。
- **本地音频库**：覆盖该 displayName 的库 DB。
- **书 epub**：替换解压目录的 epub 内容；**阅读进度/统计独立存储，不被书本覆盖牵连**（选 A 的前提，测试守护）。

mtime 来源：manifest.mtime（上传方写入时的资产源文件修改时间）；本地侧用资产源文件的代表性 mtime（词典资源目录 / audio DB 等，每类定义"代表 mtime"）。

## 7. 云端完整性四层防线（G4）

回答"云端数据怎么保证完整未损坏"——从弱到强：

1. **manifest 写在内容之后（commit 标记）**：内容整文件传完**成功后才写 manifest.json**。"传一半"的文件永远没有配套 manifest，不被误当好数据。
2. **上传后查 size（所有后端，廉价）**：上传后用列目录/HEAD 的大小与 manifest.size 比，**截断（最常见损坏）当场发现**，全后端支持。
3. **原生 hash 回比（仅 Drive/Dropbox/OneDrive，廉价）**：上传后从元数据白拿服务器算的 hash 与我们的 md5 比一次，内容级损坏在上传端确认；无原生 hash 的后端降级到第 2 层。
4. **下载端 md5 校验（所有后端，终极保证）**：任何设备下载后用 manifest.md5 校验，对不上拒绝落地。**坏数据永远不会被任何设备用上。**

无原生 hash 的后端无法在上传端 100% 确认内容级正确（TLS/SSH 传输层已有完整性校验，飞行中损坏极罕见），但截断在上传端能查、内容损坏在下载端必被挡。这是不依赖各后端 hash 能力还能给的最强保证。

第 2、3 层收口成一个后端接口方法 `verifyRemoteAsset(assetId, expectedMd5, expectedSize)`：有原生 hash 的实现比 hash，没有的只比 size。特例被封在这一个方法里，不外泄。

## 8. 附带清理：删除"同步有声书位置"开关

与本设计同属同步清理：删掉 `sync.audiobook` 开关，**有声书位置永远同步**（小 JSON、几十字节，没有"不同步"的合理场景，开关只是多余的认知负担）。

- 删 `sync_settings_schema.dart` 的 `SettingsSwitchItem(id: 'sync.audiobook')`（line 152-162）+ `_SyncSettingsState.syncAudioBook` 字段及其 `load()`。
- `sync_auto_trigger.dart` 两处 `syncAudioBookPosition: await repo.isSyncAudioBookEnabled()` → 恒 `true`。
- `sync_orchestrator.dart` 的 `syncAudioBookPosition` 门控恒为开（可直接移除该 gate 参数，位置无条件同步；牵动 `sync_manager` 的 `syncAudioBook` 分支一并简化）。
- i18n：`dart run tool/i18n_sync.dart --remove sync_audiobook`，再 `dart run slang` + `dart format`。
- `SyncRepository.isSyncAudioBookEnabled/setSyncAudioBookEnabled` + 持久化键 `sync_audiobook_enabled`：移除访问器；旧持久化值无害遗留，不做迁移。
- 测试：删 `sync_gating_test.dart:215` 的位置开关测试；`sync_orchestrator_test` / `sync_orchestrator_conflict_test` 中传 `syncAudioBookPosition: false` 的调用按"位置恒同步"更新或移除该参数。

> **注意**：只删"有声书**位置**"开关（`sync.audiobook`）。"有声书**文件包**"开关（`sync.audiobook_files`，大文件、默认关）是另一回事，保留不动。

## 9. 错误处理

- 下载 md5 校验失败：删临时文件，`report.errors` 记 `"<name>: content hash mismatch"`，本轮不自动无限重试（下次同步再来）；不污染本地。
- 远端缺 manifest（旧数据）：pull 校验降级跳过，push 侧顺手补写 manifest（自愈）。
- manifest 解析失败/字段缺失：当作"无 manifest"降级处理，不抛。
- md5 计算 / verifyRemote IO 错误：上抛到 `report.errors`，跳过该资产，不中断整轮同步。

## 10. 测试策略

- **纯函数**：`sync_content_hash` 的 md5 正确性 + 缓存命中/失效（size/mtime 变更触发重算）——可在 host 跑。
- **决策逻辑**：纯函数 `decideAssetAction({localMd5, localMtime, remoteManifest})` 返回 `skip/pullOverwrite/pushOverwrite/pullNew/pushNew`，单测全分支（同 `resolveProgressSync` 范式）；专门覆盖"mtime 相等 → md5 字典序 tiebreak 两端算出同一方向"的收敛性。
- **编排器集成**（现有 in-memory / fake backend 测试套）：
  - 损坏的远端资产（manifest.md5 与内容不符）被拒绝 import；旧无-manifest 资产仍可 pull。
  - 同名 md5 不同时按 mtime 覆盖正确方向；epub 覆盖后阅读进度保留（守护测试）。
  - 上传后 size/原生 hash 回比：fake backend 模拟截断 → 上传端报错。
- **源码守卫**：扫描确保四个 `sync*` 的 pull 都走 `_getAssetVerified`、push 都走 `_putAssetWithManifest`，防止新增同步路径漏挂校验。
- **清理回归**：有声书位置在无开关时仍正确同步（位置恒 gate-on 的集成断言）。

## 11. 向后兼容

- 旧远端数据无 manifest：pull 降级跳过校验、push 自愈补写，不报损坏。新名字 `hibiki-data` 根（见 2026-06-05 改名）下从零重建时本就带 manifest。
- union 语义变化（开始传播内容更新）是行为变更点——PR 说明 + 测试守护进度不被牵连。
- 删有声书位置开关：旧持久化键遗留无害，不迁移。

## 12. 风险

- **覆盖/重导入语义**是最大风险点：重导入若中途失败必须回滚，不能让本地处于半覆盖状态——这正是"先写临时文件、校验通过再原子替换"的理由。
- 大文件 md5 成本：临时文件本就要读（零额外）；本地已存在大资产靠 §4 缓存消除稳态重算，首次/变更后仍要全量读一遍（IO 成本，不可避免，但只一次）。
- mtime 可信度：依赖各设备时钟。时钟回拨只影响"拿到哪版"，不影响完整性（md5 兜底）；mtime 相等的退化情形用确定性 md5 字典序 tiebreak 保证收敛，不留 divergent 状态。
