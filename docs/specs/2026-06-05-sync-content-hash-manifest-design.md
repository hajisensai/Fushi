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

- **G1（防损坏）**：下载完成后用已知 md5 校验文件，损坏/截断则丢弃重试，绝不污染本地。
- **G2（内容更新传播）**：同名但内容不同的大资产，按"修改时间新的胜"自动覆盖，且覆盖前先落临时文件校验、通过才原子替换。
- **G3（全后端一致）**：机制不依赖任一后端的原生 hash 能力。
- **G4（不重复算 hash）**：大文件（可达数百 MB）的本地 md5 必须缓存，文件未变不重算。

### 非目标

- 不做块级/增量同步（rsync 式 delta）；整文件粒度。
- 不为大文件内容冲突做交互式弹窗（A：mtime 自动胜，已与用户确认）。
- 不改小 JSON（progress / stats / audiobook position）的现有时间戳同步机制。
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
- `size`：字节数（md5 之前的廉价预筛）。
- `mtime`：**上传方写入时的本地资产文件修改时间戳（毫秒）**，作为 G2 的"谁更新"判据。注意这是"资产被生成/导出的时间"，不是文件传到云端的时间。

> 为什么不用现有的 `AssetEntry.sizeBytes` 或后端 mtime：WebDAV PROPFIND 不返回大小、各后端 mtime 语义不一（上传时间 vs 修改时间），不可移植。manifest 把这三个值变成我们自己写、自己读的数据，消除后端差异。

### 3.2 manifest 命名约定

`<assetName>.manifest.json`，例如：

- 词典包 `物書堂.hibikidict` → `物書堂.hibikidict.manifest.json`
- 有声书包 `audiobook.hibikiaudio` → `audiobook.hibikiaudio.manifest.json`
- 书 epub `content.epub` → `content.epub.manifest.json`

manifest 自身在 union 的名字集合里要被**排除**（`isReservedSyncFolderName` 同理新增 `.manifest.json` 后缀过滤），不能被当成一个待同步资产。

## 4. 本地 md5 计算与缓存（G4）

新增 helper `hibiki/lib/src/sync/sync_content_hash.dart`：

```dart
/// 流式计算文件 md5（不整文件进内存），返回小写 hex。
Future<String> computeFileMd5(File file);

/// 带缓存的 md5：缓存键 (绝对路径, size, mtimeMs)；命中直接返回缓存值，
/// 未命中或 size/mtime 变化时重算并写缓存。
Future<String> cachedFileMd5(File file, ContentHashCache cache);
```

缓存落 Drift `preferences` 表（或新增一张窄表 `content_hash_cache(path, size, mtime, md5)`，实现计划定）。键含 size+mtime，文件一改就自然失效。流式实现用 `package:crypto` 的 `md5.bind(file.openRead())`。

## 5. 改动触点（全部在编排器层）

所有 push/pull 都经过 `sync_orchestrator.dart` 的统一接缝（`_backend.putAsset` / `_backend.getAsset`），manifest 收口成两个私有 helper：

```dart
/// push 资产后立即写 manifest（md5 取自刚导出的临时文件）。
Future<void> _putAssetWithManifest(String ns, String name, File file, {onProgress});

/// pull：下载到临时文件 → 读远端 manifest → 校验 md5 → 通过才返回 true。
/// 校验失败删临时文件、上抛或记 error，绝不交给上层 import。
Future<bool> _getAssetVerified(AssetEntry asset, String manifestId, File tmp, {onProgress});
```

涉及的同步路径：书 epub 的 push / pull（`sync_orchestrator.importRemoteBooks` + `sync_manager` 中的书内容导入/导出触点，实现计划逐一定位）、`syncDictionaries`、`syncLocalAudioPackages`、`syncAudiobookPackages`。规则统一：所有 `putAsset` 调用点换成 `_putAssetWithManifest`，所有 `getAsset` 调用点换成 `_getAssetVerified`。书 epub 散落在 `sync_manager` 的具体函数（`_importContentIfMissing` 等）需在计划阶段逐一确认后挂接，不在本设计写死。

## 6. 分两期实施

### 一期（G1 防损坏 + 地基，低风险，无覆盖语义）

1. `sync_content_hash.dart`：流式 md5 + `(path,size,mtime)` 缓存。
2. push 侧：每次 `putAsset` 后写 `<name>.manifest.json`。
3. pull 侧：下载到临时文件后，读远端 manifest，先比 size 再比 md5；不符 → 丢弃临时文件、记 error、不 import。
4. union 名字集合排除 `*.manifest.json`。
5. **行为不变点**：仍是 union（两边都有仍跳过）；只是 pull 多了一道校验、push 多写一个小文件。向后兼容：远端**没有** manifest 的旧资产，pull 时校验降级为"跳过校验"（不能因旧数据没 manifest 就判损坏）。

一期交付后：损坏/截断能被发现并重试；已有同名资产行为不变。

### 二期（G2 内容更新传播，A=mtime 胜，原子覆盖）

把四个 `sync*` 的"两边都有 → 跳过"改为：

```text
两边同名都有：
  读远端 manifest.md5 与本地 cachedFileMd5：
    相同        → 跳过（内容一致，比现在的"同名即跳过"更可信）
    不同：
      远端 mtime 更新 → pull 到临时文件 → md5 校验 → 通过才【原子重导入】覆盖本地
      本地 mtime 更新 → 重新导出 → putAsset + 覆盖远端 manifest
      mtime 相等但 md5 不同 → 平手保守跳过并记一条诊断（极罕见，避免来回覆盖抖动）
```

"原子重导入覆盖本地"按资产类型分别落地（这是二期的真实复杂度，每类一个子任务 + 测试）：

- **词典**：导入到临时资源目录 → 成功后替换正式目录 + 更新 DB 行；失败回滚，不破坏现有词典。
- **有声书包**：重新 import 覆盖该 book 的 audio DB（已有 `bookUidOverride` 重键路径可复用）。
- **本地音频库**：覆盖该 displayName 的库 DB。
- **书 epub**：替换解压目录的 epub 内容；**阅读进度/统计独立存储，不被书本覆盖牵连**（这是选 A 的前提，需在测试中守护）。

mtime 来源：manifest.mtime（上传方写入时的资产文件修改时间）。本地侧用资产源文件的实际 mtime（词典资源目录、audio DB 等的代表性 mtime；实现计划为每类定义"代表 mtime"）。

## 7. 错误处理

- 下载 md5 校验失败：删临时文件，`report.errors` 记 `"<name>: content hash mismatch"`，本期内**不**自动无限重试（下次同步再来一次）；不污染本地。
- 远端缺 manifest（旧数据）：pull 校验降级跳过，push 侧顺手补写 manifest（自愈）。
- manifest 解析失败/字段缺失：当作"无 manifest"降级处理，不抛。
- md5 计算 IO 错误：上抛到 `report.errors`，跳过该资产，不中断整轮同步。

## 8. 测试策略

- **纯函数**：`sync_content_hash` 的 md5 正确性 + 缓存命中/失效（size/mtime 变更触发重算）——可在 host 跑。
- **决策逻辑**：抽一个纯函数 `decideAssetAction({localMd5, localMtime, remoteManifest})` 返回 `skip/pullOverwrite/pushOverwrite/pullNew/pushNew/tie`，单测全分支（同 `resolveProgressSync` 范式）。
- **编排器集成**：用现有 in-memory / fake backend 测试套验证：
  - 一期：损坏的远端资产（manifest.md5 与内容不符）被拒绝 import；旧无-manifest 资产仍可 pull。
  - 二期：同名 md5 不同时按 mtime 覆盖正确方向；epub 覆盖后阅读进度保留（守护测试）。
- **源码守卫**：扫描确保四个 `sync*` 的 pull 都走 `_getAssetVerified`、push 都走 `_putAssetWithManifest`，防止新增同步路径漏挂校验。

## 9. 向后兼容

- 旧远端数据无 manifest：pull 降级跳过校验、push 自愈补写，不报损坏。新名字 `hibiki-data` 根（见 2026-06-05 改名）下从零重建时本就带 manifest。
- 一期纯增量（多一个小文件 + 一道校验），不改变哪些资产被同步。
- 二期改变 union 语义（开始传播内容更新），是行为变更点——需在 PR 说明并以测试守护进度不被牵连。

## 10. 风险

- **二期覆盖语义**是最大风险点：重导入若中途失败必须回滚，不能让本地处于半覆盖状态——这正是"先写临时文件、校验通过再原子替换"的理由。
- 大文件 md5 成本：靠 §4 缓存消除稳态重算；首次/变更后仍要全量读一遍文件（IO 成本，不可避免，但只一次）。
- mtime 可信度：依赖各设备时钟。时钟回拨可能误判方向；平手保守跳过 + 诊断日志兜底。
