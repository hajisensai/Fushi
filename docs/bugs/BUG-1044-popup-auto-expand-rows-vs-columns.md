## BUG-1044 · 折叠词典「自动展开词典数」与「词典列数」冲突：绝对本数不随列数对齐致顶部参差

- **报告**：2026-07-23（用户：反馈「折叠词典显示 自动展开词典数」和「词典列数保持一致」这两件事冲突）
- **真实性**：✅ 真 bug（设计层面的单位错配，非偶发）

### 根因

两个设置分别用了**互不相关的两套单位**，于是只要展开本数不是列数的整数倍，弹窗顶部就参差：

- `自动展开词典数`（`autoExpandDictionaries`，0..6）是**线性本数**：
  `hibiki/assets/popup/popup.js:2574`（修前）`const autoExpandN = window.autoExpandDictionaries ?? 1;`
  配合下一行的 `dictIdx < autoExpandN`，只认词典在词条内的**顺序**，完全不知道有几列。
- `词典列数`（`--dict-columns`，1..4）是**网格单位**：`layoutMasonry()` 按「最短列打包」
  （判据 `heights[i] < heights[c]`）把所有 `.glossary-group` 卡片塞进
  `cols = Math.min(configured, items.length)` 列。

**失效路径**（K=展开本数，N=列数）：K < N 时，前 K 本展开成高卡各占一列顶部，剩余折叠矮条因为
其余列高度仍是 0，全部被「最短列」规则堆到那几列 —— 出现「一列一张大卡 vs 另一列一摞折叠条」。
K 与 N 非整数倍时同理出现半行展开的参差。

即：`autoExpandDictionaries` 与 `--dict-columns` 之间没有任何契约，用户把两个滑块当作能配合的
设置来用，实际互相打架。

### 修复

把「自动展开」的单位从**本数**重锚为**行数**，展开数由列数派生，冲突从数据结构上消失：

- 新增 `autoExpandCount(totalDicts)`（`hibiki/assets/popup/popup.js:2566`）：
  `展开数 = window.autoExpandRows × Math.max(1, Math.min(dictColumns(), totalDicts))`。
  列数来源 `dictColumns()`（= 视口收敛后的 `effectiveDictColumns()`）并对该词条**实际卡片数**
  封顶，与 `layoutMasonry()` 的 `cols = Math.min(configured, items.length)` **严格同源**，因此
  词典数 < 列数时不会凭空展开不存在的卡。
- `createGlossarySection` 增加 `totalDicts` 形参；首屏渲染循环传 `dictNames.length`，增量
  （load-more）路径传 **post-append** 的 `appendIndex + appendDictNames.length`（只数已渲染的
  会低报列数，误折叠本该展开的卡）。
- 宿主注入 `window.autoExpandDictionaries` → `window.autoExpandRows`
  （`hibiki/lib/src/pages/implementations/popup_settings_injection.dart:313`）。
- 文案改为「自动展开行数」（i18n key 名不变，17 语经 `tool/i18n_sync.dart` 同步）。

**向后兼容**：偏好存储 key 仍是 `popup_auto_expand_dictionaries`、clamp 仍 0..6，**值不迁移**。
默认列数为 1，`rows × 1 === 旧的绝对本数`，从未调过列数的老用户观感零变化。

- **[x] ① 已修复** — popup.js（三镜像同步：`hibiki/assets/popup/`、
  `hibiki/assets/browser_extension/vendor/`、`tools/browser-extension/vendor/`）+ 注入 + 文案 + 偏好注释。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/pages/popup_auto_expand_dictionaries_test.js`：Node 真执行 `createGlossarySection`，
    覆盖 1 列向后兼容、rows=0、缺省回落，以及新契约 **2 列×1 行=顶行 2 张 / 2 列×2 行=4 张 /
    3 列×1 行=3 张**、**列数被词条卡片数封顶**（4 列设置 + 2 本词典 → 2 列）、**窄视口收敛**
    （innerWidth=300 → 1 列）。
  - `hibiki/test/pages/popup_auto_expand_dictionaries_test.dart`：源码级守卫 `rows * cols`、
    `Math.min(dictColumns(), total)`、`rows > 0` 短路、两处调用点必须传 totalDicts、增量
    totalDicts 必须是 post-append 计数。
  - `hibiki/test/settings/settings_schema_coverage_test.dart`：覆盖登记随标题改名同步。

### 备注

- 未改 Dart 侧 getter/setter 名（`popupAutoExpandDictionaries`），避免无谓爆炸半径；单位语义已在
  `preferences_repository.dart` 注释里写明。
- 采番：本 PR 原取 BUG-1041，集成阶段连撞两次——`develop` 已占 BUG-1041
  （global-lookup-card-corner-asymmetry，#366），改到 BUG-1042 后 rebase 又遇并发落地的
  BUG-1042（ios-generated-xcconfig-tracked）与 BUG-1043，最终改为下一空号 BUG-1044 并 reindex。
- 验证：`flutter analyze` 无问题；相关测试 + i18n 完整性通过。真机（弹窗多列 × 多行组合的观感）待复测。
