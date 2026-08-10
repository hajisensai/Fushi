## BUG-1502 · 书改名跨端合并无时刻列做不了 LWW（第二次改名传不到子设备）
- **报告**：2026-08-11（BUG-1488 收尾时自曝的能力缺口，用户拍板「全部修复」）
- **真实性**：✅ 真 bug（BUG-1488 正文「备注」段已写明是**已知缺口不是遗漏**）。
  书的改名不写 `epub_books.title`（那列派生主键 `bookKey`），而是写一行覆盖偏好
  `src:reader_fushi:override_title://fushi://book/<bookKey>`。根因是**这行数据没有
  时刻**：`preferences` 表在 v83 只有 `key`/`value` 两列
  （`packages/fushi_core/lib/src/database/tables.dart:272-278`，改前），于是所有
  跨端合并端只能退化成 insert-if-absent：
  - 备份合并 `BackupMergeEngine._mergeOverrideTitlePrefs`
    （`fushi/lib/src/sync/backup_merge_engine.dart:1243-1250`，改前）：
    `NOT EXISTS` 才插；
  - 互联下载后采纳 `_adoptRemoteBookDisplayTitle`
    （`fushi/lib/src/pages/implementations/reader_history/remote.part.dart:506-525`，改前）：
    `if (source.overrideTitleForBookKey(...) != null) return;`。
  后果：母设备**第二次**改名永远传不到「本机已有 override」的子设备（只有第一次、
  以及子设备从没自己改过名的书才生效）。清单 DTO `RemoteBookInfo` 也只带
  `displayTitle` 不带时刻（`fushi/lib/src/sync/fushi_library_host_service.dart:229-311`，改前），
  所以接收端连做 LWW 的原料都没有。

- **[x] ① 已修复** — `1c9a0e1e4a`。**Drift schema v83 → v84**，给 override 一个时刻载体
  并把三条通道统一到同一条裁决规则。
  - **schema**：`Preferences` 加 `IntColumn updatedAt`（int 毫秒、无 `Ms` 后缀，
    withDefault 0，`packages/fushi_core/lib/src/database/tables.dart`）。
    **不新开表**：override 的值本来就在 `preferences` 行上，另开一张
    `BookCustomCss` 式的侧表会造出「值在这边、时刻在那边」的双真相源，任何一处漏写
    就漂；加一列则写入点单一（`setPref`），且所有偏好白拿时刻。
  - **迁移**：`database.dart` `onUpgrade` 里 `if (from < 84) addColumn`。
    ⚠️ **这一步刻意排在整条阶梯最前**（下沉在末尾会炸）：后面的迁移步会用 drift
    的**类型化** API 读写 preferences（`migrateLegacyBookmarkPreferences` →
    `getAllPrefs()`），类型化行映射按代码列集取值，列还没加时对缺失列做 null 断言
    直接把整条 `onUpgrade` 打断（实测 `migration_orphan_bookmark_test` 转红）。
    加列是纯 additive + `_columnExists` 幂等守卫，提前执行对任何版本老库都等价。
  - **存量行取 0（=「时刻未知」），不取迁移时刻** —— 这个取舍决定「升级后第一次
    跨端同步谁赢」：取迁移时刻会让胜负由两台设备各自的**升级时间**决定，后升级的
    一侧无条件覆盖先升级一侧的全部存量改名，而用户什么都没做；取 0 则存量行彼此
    平局，而 LWW 的平局规则是「保留本机」，**逐字等于升级前的 insert-if-absent
    行为（零回归）**，任一侧真正改过一次名（戳 > 0）之后立刻胜出。
  - **LWW 原语**：`FushiDatabase.setPrefIfNewer(key, value, {updatedAt})`
    （`database_prefs_media.part.dart`）——严格更新才写 / 平局保留本机 / 本机无该行
    则无条件采纳；**戳落成对端的戳而不是 `now`**（戳 now 会让本机永远最新，对端的
    下一次改名再也进不来，正是本 bug 的形状）。真写入时才 bump prefs 版本。
    本地写入侧 `setPref` / `setPrefs` / `compareAndSetPref` 一律戳 `now`。
  - **三条通道统一**（语义不一致就等于没修）：
    ① 互联清单下发：`RemoteBookInfo.displayTitleAt` additive wire 键（只在真改过名
    且戳 > 0 时写），host 侧 `_overrideTitleByBookKey` 改读 `getAllPrefRows()` 带戳；
    ② 下载后采纳：`MediaSource.adoptOverrideTitleIfNewer` 走 `setPrefIfNewer`，
    并按返回值同步写穿源的内存偏好缓存（只写 DB 的话书架会一直显示旧名）；
    ③ 备份合并：`_mergeOverrideTitlePrefs` 从单条 insert-if-absent 改成
    insert-missing + update-strictly-newer 两条语句（与 `_mergeRevealedImages` 同形）。
  - **旧对端降级语义：无时刻的一方输**。旧 host / 旧备份 → 戳 0 → 与本机平局 →
    保留本机；本机没有该行时仍照常采纳。理由：无戳者**无法证明**比本机新，保守不
    覆盖用户刚敲进去的名字，且这恰好使旧对端场景逐字退回 BUG-1488 的行为。
    旧版本 app 打开新库不会崩——加列是 additive，且 v84 库对旧 app 走的是既有的
    降级保护（`FushiDatabaseDowngradeException`，拒绝打开而非破坏）。
  - **共享查询**：新叶子 `fushi/lib/src/sync/override_title_lookup.dart`
    （`readOverrideTitlesByBookKey`），host 下发与 push 上行（BUG-1503）共用一份，
    不再各写一遍。
  - **BUG-1317 存量收敛**：采纳前先把还躺在旧键上的本机改名就地搬到规范键、**戳 0**
    （搬家不是改名，戳 `now` 会让本机凭空变新）。不收敛的话规范键不存在会被 LWW
    误判成「本机没改过名」而无条件采纳对端。

- **[x] ② 已加自动化测试** —
  `fushi/test/database/migration_v84_preferences_updated_at_test.dart`（7 例）：
  v83→v84 加列无损 + 存量行戳 0；本地写入三入口恒戳 now（含 `setPrefs` 一组同戳）；
  `setPrefIfNewer` 三条裁决；行不存在时戳 0 也采纳；存量行挡不住真改名但挡得住旧
  对端；写入才 bump 版本；`getPrefUpdatedAt`。
  `fushi/test/sync/book_rename_lww_test.dart`（13 例，与 BUG-1503 共用）：wire 戳
  additive + 往返 + 旧 host 缺键回落 0；host 清单下发戳；**母设备改名两次 → 已有本机
  override 的子设备最终显示最新那个**；戳相等保留本机；旧对端戳 0 不覆盖本机但仍
  采纳本机没有的书；备份合并四象限（更新覆盖 / 更旧不覆盖 / 平局保留 / 缺失采纳）。
  **变异实测**（2026-08-11，逐条破坏 lib → 确认转红 → **反向替换**还原，零 lib 残留）：
  ① `setPrefIfNewer` 判据 `>=` → `>`（平局改判对端赢）→ 2 例转红；
  ② 同函数 `updatedAt: Value(updatedAt)` → 写 `now` → 8 例转红；
  ③ host `displayTitleAt: …?.updatedAt ?? 0` → 恒 `0` → 1 例转红；
  ④ wire 键 `'displayTitleAt'` → `'displayTitleAtX'` → 1 例转红；
  ⑥ `_mergeOverrideTitlePrefs` 的 update-newer 语句删掉 → 1 例转红。

- **备注**：迁移阶梯的既有测试断言了 `schemaVersion == 83`，本轮一并推到 84
  （42 处 + 4 处非常规写法）；`migration_v63_legacy_galgame_upscaling_pref_test`
  的「v63 不得 ALTER 既有表」形状守卫按 v75 给 galgames 加列的同一范式，为
  preferences 的 `updated_at` 加了「摘掉该列后必须逐字节相同」的豁免（不弱化原意图）。
  `packages/fushi_core/test/migration_orphan_bookmark_test.dart` 的 fixture 刻意
  seed 成 current 版本让 onUpgrade 不跑，故其 `CREATE TABLE preferences` 也补了该列。
  **未做真机双设备验证**（母/子两台真设备互联对拉）——只有单测覆盖。
