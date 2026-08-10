## BUG-1491 · Anki 媒体去重逐个删除过慢
- **报告**：2026-08-10（用户：「真就一个一个删，感觉要删很久啊」——设置里的「Anki 媒体存储优化」）
- **真实性**：✅ 真 bug。根因 `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart:1477`（修复前的 `runMediaDedup` resolving 循环，逐个副本串行发请求）+ `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart:455`（`deleteMediaFile` 每次一个独立 HTTP 往返）。

### 实测瓶颈（不是磁盘、不是哈希）
用假 backend 跑 120 个重复副本，按动作数往返：

```
总往返 606 = getMediaDirPath 1 + modelNames 1 + modelTemplates 2 + modelStyling 2
           + findNotes 240 + notesInfo 120 + updateNoteFields 120 + deleteMediaFile 120
```

即 **每个副本恰好 5 次独立 AnkiConnect 往返**（判定 findNotes → notesInfo → updateNoteFields → 复核 findNotes → deleteMediaFile），常数开销只有 6 次。用户报告的量级（940 个副本）≈ **4706 次往返**。

往返本身为什么这么贵——查 AnkiConnect 插件源码（`plugin/web.py` / `plugin/util.py`）：
- HTTP 服务是 **协作式轮询**：`QTimer` 按 `apiPollInterval`（默认 **25 ms**）触发一次 `advance()`；
- `acceptClients()` 每个 tick 只 `accept()` **一条**连接（不是循环 accept）；
- 全链路同步跑在 **Anki 的 Qt 主线程**上，响应写完即 `close()`（**无 keep-alive**，每个请求都要新建 TCP）。

所以**每个请求的地板成本 = 一次 TCP 建连 + 至少一个 25 ms tick，与请求大小完全无关**。4706 次往返 ≈ **118 秒纯轮询等待**，还没算 Anki 主线程上 1880 次全库 `findNotes` 文本检索的真实执行时间。这就是用户看到的「一个一个删、要删很久」。

扫描/哈希阶段不是瓶颈：只对「大小撞车」的候选算全文件 sha256，940 组约 380 MB 本地顺序读，秒级。

### 修法
把这些请求打进 AnkiConnect 的 `multi`（一次往返执行 N 条子 action）。
- 服务层新增带类型签名的批量入口：`AnkiConnectService.requestMulti(List<AnkiConnectAction>)`（**恰好一次** HTTP POST）+ `deleteMediaFiles` / `updateNoteFieldsMany` / `findNotesByQueries` 三个 typed 包装（按 `kMultiBatchSize = 100` 切块）。每条子 action 显式带 `version: 6`——不带时成功值是裸值、失败才是信封，同一数组里两种形状无法可靠区分。
- 编排层把 resolving 从「逐副本串行」改成「按 `kAnkiMediaDedupBatchSize = 50` 分批，批内 5 个阶段各一次往返」：批量 findNotes 判定 → 批量 notesInfo 拉字段快照 → 本地过安全闸 → 批量 updateNoteFields（**按笔记合并**）→ 批量复核 findNotes → 批量 deleteMediaFile。
- 不做「老 AnkiConnect 没有 multi」的回退分支：`multi` 自 2017 年就在且无版本门槛，而本链路依赖的 `getMediaDirPath` 是 2023 年才加的——能走到这里的 AnkiConnect 必然支持 `multi`。

**同一条笔记被同批多个副本命中必须合并改写**：`updateNoteFields` 是整字段覆盖，各算各的再分别写回，后写会把先写抹掉，笔记里就留下一个指向已删文件的引用（问号方框 / 放不出声）。合并 = 在同一份字段原值上依次套用每个副本的 `dupe → canonical` 边界安全替换，结果与旧实现逐个串行改写逐字一致。

**结果（同一假 collection，120 副本）：606 → 21 次往返（28.9×）**。按 940 副本外推 4706 → 101 次（46.6×），25 ms/往返口径下 ~118 秒 → ~2.5 秒。

### 安全语义：全部保持不变
仍然只删字节完全相同的多余副本、仍然先写 journal 到备份文件夹、仍然「先改指保留份 → 复核引用清干净 → 才删文件」、仍然可取消。批内单条失败**不吞**：`multi` 逐条返回 error，删除失败/改写失败/检索失败各自只让对应副本计入 `skipped`，同批其余照常处理；检索失败**绝不降级成空列表**（那会删掉仍在用的媒体）。

**唯一让步：取消粒度从「副本边界」变粗到「批边界」**（50 个副本一批，批内不可中断）。批内还额外在「判定完、动手前」补了一次取消检查，所以取消落在纯读阶段时一个字节都不会写。取消延迟量级 = 一批的 5 次往返 + Anki 主线程上约 100 次全库检索，秒级；这是用 `kAnkiMediaDedupBatchSize` 显式换来的，常量注释里写清了取舍。

### 后端不对称
AnkiDroid（`AnkiRepository`）与 AnkiMobile **不覆写** `supportsMediaMaintenance` / `runMediaDedup`，即 `false` / `null`——这两个后端根本不跑媒体去重，不存在对称的「逐条删除」缺口需要补。已把这条写进 `base_anki_repository.dart:251` 的文档注释，免得后来人以为漏改了一半。

### 有意未改
note type 快照（`modelTemplates` + `modelStyling` 每个 note type 各一次）仍是逐个往返：它是 O(note type 数) 而不是 O(副本数)，20 个 note type = 40 次往返，在 4706 次的背景里是噪声。批量化它只会扩大 diff。

- **[x] ① 已修复** — `85c2479e92`
  - `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart`：`requestMulti` / `deleteMediaFiles` / `updateNoteFieldsMany` / `findNotesByQueries` + `AnkiConnectAction` / `AnkiConnectBatchResult` / `AnkiNoteFieldsUpdate`
  - `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart`：`runMediaDedup` 分批编排 + `_planDedupChunk` / `_rewriteNoteFieldsBatch` / `_rewriteModelsBatch`
  - `packages/fushi_anki/lib/src/anki_media_dedup.dart`：`kAnkiMediaDedupBatchSize`
  - `packages/fushi_anki/lib/src/base_anki_repository.dart`：后端不对称成文
- **[x] ② 已加自动化测试** — `85c2479e92`，`packages/fushi_anki/test/anki_media_dedup_batching_test.dart`（12 条）
  - 核心不变量：N 个副本的删除只发 `ceil(N/kAnkiMediaDedupBatchSize)` 次往返、总往返数 `< N`
  - 干跑（用户确认前那一遍）同样批量：每批 2 次往返、零写入
  - 批内单条删除失败 / 单条笔记改写失败 / 单条检索失败：各自只让该副本 `skipped`，同批其余照删
  - 同一条笔记引用同批多个副本 → 合并改写，后写不抹掉先写
  - 进度按批推进、`done` 单调且收敛到 `total`
  - 服务层：`requestMulti(N)` = 恰好 1 次 HTTP POST、子 action 带 `version: 6`、超 `kMultiBatchSize` 按批切、逐条 error 透出、结果条数对不上则抛
  - 取消语义改由 `anki_media_dedup_orchestration_test.dart` 的「取消在批边界干净生效」覆盖（常量相对，不写魔数）
  - **变异实测**（反向替换还原，未对未提交文件用 `git checkout --`）：M1 批大小失效→3 条红（含核心不变量）；M2 不合并同笔记改写→1 条红；M3 检索失败降级成空列表→2 条红；M4 删除失败不计 skipped→1 条红。
- **备注**：未验证缺口——**没有真 Anki 实例做端到端计时**。606→21 是假 backend 上的往返计数，25 ms/往返的换算来自 AnkiConnect 源码常量（`apiPollInterval` 默认 25、每 tick 单次 accept），不是实测墙钟。真机上还要叠加 Anki 主线程执行 `findNotes` 全库检索的时间，那部分批量化只省了调度开销、没省检索本身。
