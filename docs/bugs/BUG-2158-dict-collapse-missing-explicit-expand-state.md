## BUG-2158 · 词典折叠只有两个态：点「展开」对自动展开窗口外的词典毫无反应
- **报告**：2026-09-05（用户：「为什么查词没有按照我设置的词典排序和折叠方式」，附查词弹窗截图 + 词典管理配置截图）
- **真实性**：✅ 真 bug（折叠这一半）。**排序那一半是误判，排序没坏**：
  设置页拖动 → `dictionary_metadata.order` → `_glossariesInDictionaryOrder`（`language.dart` 唯一显式排序点）
  → popup.js 按数组序渲染（popup.js 自身完全不排序）。按用户截图**按行优先**读出来的顺序与他配置的顺序一字不差
  （缺席的那本是因为该词条下它没有释义）。观感上的「乱」来自 3 列 masonry 的**最短列打包**（见文末遗留项）。
- **根因**：折叠是**三个**态，而模型里只有一个名单装得下两个。
  - `DictionaryMetadata.collapsedLanguagesJson` 只能表达「显式折叠」；
    「不在名单里」被迫同时承担「用户要展开」和「用户没表态」两种意思。
  - 消费侧 `popup.js createGlossarySection`：
    `if (!perDictCollapsed && (autoExpanded || !window.collapseDictionaries))` ——
    「没表态」时由 `collapse_dictionaries` 决定，而它**默认 true**。
  - 而设置页 `_buildDictionaryCollapseButton` 用 `unfold_more` / `unfold_less` 把它画成一个**双态开关**。
  - 于是：用户对**自动展开窗口之外**的词典点「展开」→ 模型里根本没有那个状态可写 → 视觉上毫无反应。
    **UI 在撒谎**，这就是用户说的「没有按照我设置的折叠方式」。
- **[x] ① 已修复** — 加第三个态，schema v95 → **v96**：
  - `DictionaryMetadata` 加 `expanded_languages_json`（与 `collapsed_languages_json` 同形，default `'[]'`）；
    迁移开新台阶 `from < 96`（**不能塞进 `from < 95`**——已发布的版本号是只读的，跑过 95 的库不会再执行它，
    那批用户的写路径会直接撞 no such column，v88 那步的注释里记着这条教训的实测代价）。
  - 引擎侧 `DictionaryCollapseState{expanded, collapsed, inherit}` + `collapseStateForCode`；
    读取优先级 **显式展开 > 显式折叠 > 继承**（重叠时行为确定，不是未定义）。
  - 仓库侧 `setDictionaryCollapseState` 是**唯一写入点**并保证两个名单互斥；
    `cycleDictionaryCollapseState` 做一键三态循环（继承 → 显式展开 → 显式折叠 → 继承，
    起点是继承，所以存量用户第一次点下去得到的正是他本来以为自己在做的「展开」）。
    **旧的双态 `toggleDictionaryCollapsed` 已删除而不是并存**——留着它就等于留着一条能写出
    「两个名单都不含却自称已展开」的路径。
  - 注入侧新增 `window.expandedDictionaryNames`，与 `collapsedDictionaryNames` 成对；
    popup.js 三镜像按新优先级判 `details.open`。
  - 数据通路全线补齐，任何一处漏掉都是**静默丢用户设置**：重导继承（`preservedSettings` 两处）、
    Profile 快照读写（三处）、同步资产包读写（两处）、启动期类型自愈重建 `Dictionary(...)`（两处）、
    `path_rebase_coverage` 按列登记（一处）。
    同步包导入侧**特意不用 `_stringValue`**：它缺键就抛 `FormatException`，而本次改动之前生成的包里
    没有这个键，用它等于让所有存量同步包一导入就炸；缺键 → `'[]'`。
- **[x] ② 已加自动化测试**：
  - `fushi/test/database/migration_v96_dictionary_expanded_languages_test.dart`：从真实 v95 库出发，
    加列 / 存量行无损 / 新列默认 `'[]'`（= 全部继承 = 升级前行为逐字节一致）/ 可读写。
  - `fushi/test/models/dictionary_repository_test.dart`：三态循环、两名单互斥、只动指定语言码、重叠时读取确定。
  - `fushi/test/pages/popup_auto_expand_dictionaries_test.js`（**node 真执行 popup.js**）：
    显式展开压过自动展开窗口与全局开关；压过显式折叠；**没有新名单的旧宿主逐字节保持旧行为**。
    变异实测：把 popup.js 的优先级改回去 → 立刻红。
  - `fushi/test/pages/popup_auto_expand_dictionaries_test.dart`：三镜像源码级 —— 必须读注入名单、
    且 `if (perDictExpanded)` 必须排在旧判断**之前**；注入侧两个名单必须成对且展开名单来自
    `isExplicitlyExpanded` 而不是 `!isCollapsed`。
    顺手修了这条守卫自己的一个脆弱点：它原来用 `fn + 700` 的**魔数字符窗口**取函数体，
    本次加注释就把决策块顶出了窗口、以「表达式不见了」的名义假红；改成锚到 `const summary = el(`
    并用 `maskJsComments` 掩码注释。
  - `fushi/test/pages/dictionary_dialog_layout_static_test.dart`：按钮必须三分支、三个图标（少一个
    就意味着两个态共用一个图标 —— 正是修复前「显式展开」和「继承」长得一模一样的老毛病）。
- **遗留（本次未修，用户已知）**：`autoExpandCount` 按「行」展开的前提是**首行等高**，而「显式折叠/展开」
  允许在这批块里打洞，首行一不齐，`layoutMasonry` 的最短列打包就退化成「一张大卡 + 一摞折叠条」
  ——用户截图里第 3 列从第 2 行起全空就是这个。要修得让展开态卡片不参与最短列打包，或让
  `autoExpandCount` 跳过显式折叠的块凑满整行。与本 bug 正交，另开。
- **备注**：注入侧 `JapaneseLanguage.instance` 是**既有**的硬编码（不是本次引入），
  与「无全局学习语言」这条事实相冲，属于更大范围的历史债，本次照原样跟随、未扩大也未修。
