## BUG-1994 · 切换 profile 会删掉其他 profile 导入的词典元数据行
- **报告**：2026-09-01（用户：导了两本 yomitan 词典，明镜日中两个 profile 都能在词典库找到；牛津英汉只有导入时那个 profile 的词典库里有，另一个 profile 里没有。期望：都显示，profile 只管顺序和开关）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/profile/profile_repository.dart:227-241`（`applyProfile` 的 prune 循环）。

  BUG-500 / TODO-1077（提交 `35b4ee13f`）把「这本词典**启用中**」编码成了「`dictionary_metadata` 里这一行**存在**」，而这一行同时还承载「这本词典**已安装**」这个全局事实——两个正交语义挤进同一个存在性判据。于是 `applyProfile` 里那条「快照即真相」的 prune（快照没有的 live 行直接 `deleteDictionaryMeta`）就把「在别的 profile 里新导入的词典」当成了「本 profile 没启用它」。

  时序还原（与用户现象逐条对上）：

  | 时刻 | 事件 | 结果 |
  |---|---|---|
  | T1 | 导入「明镜日中」 | 全局表 = {明镜} |
  | T2 | 创建 Profile B | B 的快照就此定格 = {明镜} |
  | T3 | 在 Profile A 导入「牛津英汉」 | 全局表 = {明镜, 牛津}；**B 的快照仍 = {明镜}** |
  | T4 | 切到 B | 牛津不在 B 快照 → 整行被删 → **B 的词典库里消失** |
  | T5 | 切回 A | A 的快照重新 upsert → 牛津又出现 |

  两本词典的唯一差别就是「在 B 建立之**前**还是之**后**导入」。**排除**了「按目标语言过滤」那条假设：词典库列表（`dictionary_dialog_page.dart:1718-1725`）只按 `DictionaryType` 分桶，代码里根本不存在语言过滤器；开关走行内的 `hiddenLanguagesJson`，关掉只是 Switch 变灰、行仍在列表里。

  不是数据丢失（磁盘 `dictionaryResourceDirectory/牛津英汉/` 完好），但有隐患：在 B 里执行「清空词典数据库」时 `AppModel.deleteDictionaries` 枚举的是**磁盘目录**而非元数据表，会把 B 看不见的牛津一起物理删掉。
- **[x] ① 已修复** — `applyProfile` 不再 prune、也不再 insert，只把 profile 真正拥有的四列（`order` / `hiddenLanguagesJson` / `collapsedLanguagesJson` / `languageOverride`）写回**已存在**的行。新增 DB 原语 `applyDictionaryMetaProfileColumns`（`packages/fushi_core/lib/src/database/database_content_misc.part.dart`），它按 name 更新、返回受影响行数：0 = 这本词典不在库里 → 跳过，绝不 insert（`insertOnConflictUpdate` 会造出一行没有磁盘目录的幽灵元数据）。`formatKey` / `type` / `metadataJson` 三列不再被快照覆盖——那是安装事实，唯一写者是导入路径。`hasDictMeta` 哨兵保留（前 TODO-1077 的旧快照没有 dictionary_meta 行，跳过整段）。

  **复审补充（自愈必须保留）**：只「不 insert」会把**已经被咬的用户**从「切回 A 就有」变成「永远没有」——旧实现里 T5 的自愈正是 `upsertDictionaryMeta` 顺带给的，升级时如果正停在受害 profile（行已被删），新代码 UPDATE 命中 0 行、直接跳过，而且下一次 `switchProfile` 的 `snapshotCurrentSettings` 还会把它从来源 profile 的快照里一并抹掉。全仓没有任何从磁盘回填元数据的逻辑，唯一出路是重新导入。

  所以判据不是「表里有没有这一行」（那正是本 bug 的病根），而是**磁盘上有没有 `dictionaryResourceDirectory/<name>/`**：UPDATE 命中 0 行时，目录还在 → 这是被旧 prune 删掉的真行，按快照整行补回；目录不在 → 才是幽灵，跳过。判据经 `ProfileRepository` 的可选构造参数 `isDictionaryInstalled` 注入（`AppModel.isDictionaryInstalledOnDisk`），不注入时一律不回插，测试零依赖。
- **[x] ② 已加自动化测试** — `fushi/test/profile/profile_repository_test.dart`：
  - 新增 `BUG-1994: a dictionary imported AFTER another profile was created stays visible in that profile`，按上表 T1→T4 复刻时序；
  - 新增 `BUG-1994: snapshot row for a dictionary that is no longer installed must NOT be resurrected as a ghost row`（防止修法从「删多了」翻成「插多了」）；
  - 改写两条编码了旧契约的守卫（`enable list follows profile (Other pruned…)` 与 corrupt-row 那条的 `Live` 断言）——它们断言的正是本 bug 的行为。
  - 23 tests ran, all passed。
- **备注**：**语义反转需在 changelog 说明**：BUG-500 曾承诺「每个 profile 可以有不同的词典集合」，改后不再成立——新导入的词典会在所有 profile 里以默认开启状态出现。这正是本次用户明确要求的语义（「profile 只管顺序和开关」）。考虑过用「首次遇到快照缺行时把该行 `hiddenLanguagesJson` 补成隐藏」来保留旧意图，**故意不做**：那会把刚导入的新词典也一并默认关掉，比现状更违背预期。
