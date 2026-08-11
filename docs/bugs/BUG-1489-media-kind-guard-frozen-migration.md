## BUG-1489 · MediaKind 复合键守卫误判迁移冻结字面量

- **报告**：2026-08-10（发现方式：合入 `develop` 后跑 35 条目录枚举型守卫整批，227 tests 里挂 1）
- **真实性**：✅ 真 bug（守卫侧缺口，不是被守代码的问题）

### 症状

`fushi/test/tools/media_kind_persistence_guard_test.dart` 的用例
「lib/ 不得手写 `<kind>|...` 复合键字面量（只走 `MediaKind.compositeKey`）」在
`origin/develop` 上恒红，违规两条：

```
packages/fushi_core/lib/src/database/database.dart:2283: UPDATE media_collections SET cover_source = 'epub|' ||
packages/fushi_core/lib/src/database/database.dart:2287: WHERE cover_source LIKE 'epub|%'
```

引入者 `2ceccf8bda`（`feat(db)!: P3 Stage 2/v83`），已在 `develop` 上。

### 根因

守卫的规则「复合键必须由 `MediaKind.compositeKey(entryKey)` 派生」**只对运行时代码
成立**，而这两行在 `packages/fushi_core/lib/src/database/database.dart:520`
`MigrationStrategy.onUpgrade` 的 `if (from < 83 …)` 阶梯步里（`onCreate` 在 2300 行
之后，这两行确在升级阶梯内）。

迁移的语义要求**相反**：每一步都是「把升到那一版那一刻磁盘上真实存在的数据形态，
改写成下一版的形态」，必须逐字节钉死历史串。这段 SQL 的三处细节都咬死在字面量上：

- `WHERE cover_source LIKE 'epub|%'` —— 认的是**老库里已经存在**的行；
- `substr(cover_source, 6)` —— `6 == len('epub|') + 1`，切 bookKey 的偏移由字面量长度决定；
- `SET cover_source = 'epub|' || uid` —— 写回同一版的格式，留给后续版本阶梯去改。

若改成引用 `MediaKind.epub.dbValue`：将来谁改了枚举串，这段**历史**迁移的行为跟着变
—— `LIKE` 匹配不到老库里真实的 `'epub|<bookKey>'`，bookKey→uid 换键静默不做；而同一步
里不带前缀的 `shelf_entries` / `media_collection_items` 照常换成了 uid，
`cover_source` 从此永久悬空指向一个已不存在的键。那才是真事故。

所以根因是：**守卫缺一个「冻结迁移字面量」的登记出口**，规则本身对运行时是对的。

同族先例：`fushi/test/tools/book_format_discipline_guard_test.dart`
的 `_kFrozenHistoryValueFiles`（整文件粒度豁免迁移测试里的历史值）。

### 修复

`fushi/test/tools/media_kind_persistence_guard_test.dart` 加**行级登记机制**，
四把锁全过才算豁免（缺一把照旧算违规）：

1. 文件在 `kFrozenMigrationLiteralFiles`（当前只有 `database.dart`，附理由）；
2. 命中位置的**语句锚点**落在 `onUpgrade` 的 `if (from < N)` 阶梯步内
   （往上先撞见 `onCreate:` / `beforeOpen:` / `onDowngrade:` 即判否）；
3. 紧贴该语句的**连续注释块**（≤ `kFrozenMigrationMarkerWindow` 行，中间隔一行代码
   就断开）里有标记词 `frozen-migration-literal`，且它确实处在注释词法态
   （判据是掩码差：原文有、`maskCommentsAndScriptLines` 后没有）；
4. 该注释块除标记词外写够 `kFrozenMigrationReasonChars` 字理由。

配套两条自校验：

- **总数钉死**：全仓生效豁免数必须 == `kFrozenMigrationLiteralCount`（当前 2）。
  新增一条就红，逼人回来说明为什么又多一条。
- **陈旧检测**：登记文件必须存在，且必须真的还有 ≥1 条生效豁免，否则红（虚挂）。

锚点回溯按**字符偏移**做（沿 `maskCommentsAndStrings` 往回跳过被掩成空白的串内容），
不是按行找「上一行有代码」—— 后者在「SQL 收尾行同时带 `''');`」时会把锚点钉在违规行
自己身上，标记再怎么写都挂不上（这个洞是合成语料自校验当场抓出来的）。

`database.dart` 迁移旁补了 7 行注释说明为什么必须钉死历史串（给后来人的，不是给守卫的），
守卫文件头补了「迁移必须手写」这条例外的完整理由。

- **[x] ① 已修复** — `fushi/test/tools/media_kind_persistence_guard_test.dart` + `packages/fushi_core/lib/src/database/database.dart`（仅加注释）
- **[x] ② 已加自动化测试** — 同文件内 10 条**合成语料**判据自校验（`group('判据自校验（合成语料）')`）+ 2 条登记自校验（总数 / 虚挂）。合成语料与磁盘枚举零共享，逐把锁点名：去标记 / 只有普通注释 / 只有标记词没理由 / 不在迁移步内 / 未登记文件 / 运行时 `'video|' + uid` / 标记被代码行隔断 / 注释块超长把标记挤出 —— 八种形态都必须报违规；`'${row.mediaType}|${row.entryKey}'` 这种 DB 行值拼键必须不报。

### 变异实测（改的是守卫本身，故三向都打）

| 变异 | 做法 | 结果 |
|---|---|---|
| 正向（判据还在抓） | 摘掉 `database.dart` 里的标记词 | 🔴 3 条断言红（违规非空 + 总数 2→0 + 登记虚挂），15 tests ran |
| 反向（口子没开大） | 在**非登记**文件 `media_kind.dart` 里写 `'video|' + bookUid` 并贴上标记 + 长理由 | 🔴 违规恰好报出该行，15 tests ran |
| 陈旧（登记不许虚挂） | 往 `kFrozenMigrationLiteralFiles` 塞一个没有任何冻结字面量的文件 | 🔴「登记文件不得虚挂」红，15 tests ran |

三次都是**行为红**（`15 tests ran`，不是零测试执行），还原一律用反向 Edit。

- **备注**：`fushi/test/tools/media_kind_persistence_guard_test.dart` 属于「合并后必跑的 35 条目录枚举型守卫」清单，用例数 15（原 2 条 → 现 15 条），整批基线随之从 227 抬到 240。
