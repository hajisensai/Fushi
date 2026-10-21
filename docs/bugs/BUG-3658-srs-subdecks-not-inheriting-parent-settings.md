## BUG-3658 · srs-subdecks-not-inheriting-parent-settings
- **报告**：2026-10-21（用户：shishamo，「我发现没有自动继承上级，我现在得每个子卡组改」，附牌组设置截图：子牌组「排程参数」停在「单独设置」）
- **真实性**：✅ 真 bug。新建的子牌组缺省就是继承（`packages/fushi_srs/lib/src/deck.dart:228`），落成「单独设置」的是 Anki 导入：`packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart` `_newDeckSettings` 只在「父牌组本次新建且子牌组与父牌组用**同一个预设 id**」时写 `paramsMode=inherit`，其余一律 `own`。Anki 用户常给子牌组复制一份内容相同的预设，于是整棵树的子牌组全成了 own：改父牌组的记忆率 / 算法 / 自动优化管不到它们，自动优化也按每个子牌组的少量复习各自拟合。已导入的牌组没有批量改回继承的入口，只能逐个子牌组改。
- **[x] ① 已修复** — `b1ff2c9941`：导入时按「随继承的那部分设置」（记忆率、音频、算法、参数组，按本次导入开关过滤）比较子牌组与父牌组的预设，相同即继承，不再只认预设 id；牌组设置页新增「让子牌组都继承这里（n 个）」，把子树里所有单独设置的后代一次改成继承（各自的步长 / 每日上限不动），给已导入的数据用。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/apkg/srs_apkg_import_test.dart`「子牌组参数继承」两条（预设 id 不同但设置相同 → 继承、每日上限仍是子牌组自己的；记忆率不同 → 单独设置）；`fushi/test/srs/srs_pages_test.dart`「牌组设置页：「让子牌组都继承这里」把整棵子树里单独设置的后代改成继承」。变异实测：把判据退回「只认预设 id」后第一条红（`ownParams` Expected false / Actual true），修复后绿。
- **备注**：父牌组在本机早已存在、只新建子牌组的导入仍按 own 处理（父牌组本机参数可能已和 Anki 预设不同，继承会悄悄改掉子牌组的参数）；这种情况用设置页的批量按钮。
