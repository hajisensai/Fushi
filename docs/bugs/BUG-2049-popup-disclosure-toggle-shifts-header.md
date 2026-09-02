## BUG-2049 · 查词弹窗词典分组展开/收起时卡头位移且卡片凭空增高
- **报告**：2026-09-02（用户：两张同一词条弹窗截图，唯一差别是右栏「実用日本語表現辞典」一张 `▼` 展开、一张 `▶` 收起；原话「展开没展开高度和词典头位置会变动」）
- **真实性**：✅ 真 bug，两处独立根因、同一病理「几何随展开状态变化」。
  - 根因 A（**卡头横向位移**）`fushi/assets/popup/popup.css:982`（`.glossary-group[open] > summary::before`）：TODO-1337 把折叠三角从字体字形改成纯 CSS 边框三角形是对的，但展开态是靠**重设四条边框**换朝向的。边框三角的布局盒尺寸 = 它两组对边之和，所以「换朝向」必然「换盒子」：收起态 `border-left:5px` + 上下各 4px 透明 → 盒 **5px 宽 × 8px 高**；展开态 `border-top:5px` + 左右各 4px 透明 → 盒 **8px 宽 × 5px 高**。`::before` 是 `inline-block`，盒宽 5→8 把后面的 `.dict-name` 整体右推 3px。
  - 根因 B（**卡片凭空增高**）`fushi/assets/popup/popup.css:994`（`.glossary-group > div[data-dictionary] { padding-top: 2px }`）：卡头与释义之间的 2px 呼吸挂在内容 div 上，而该 div **只在展开态参与布局**（`<details>` 收起时子节点不生成盒子）。于是展开一本在此词条下没有可见释义的词典（截图里的「実用日本語表現辞典」正是展开后空白）也会凭空长高 2px；popup.js `layoutMasonry` 逐列绝对定位重排，再把这 2px 放大成整列上下跳动，即用户看到的「NHK 那张卡跟着挪」。
  - **实测**（headless Edge = Windows WebView2 引擎，加载真 `popup.css` + 真 DOM 形状 `<details.glossary-group><summary.dict-label><span.dict-name>`，Noto CJK / Yu Gothic / Meiryo / 系统默认 四种字体结论完全一致）：

    | | 收起 `▶` | 展开 `▼`（内容为空） | delta |
    |---|---|---|---|
    | `.dict-name` 相对 summary 左偏移 | 10px | 13px | **+3px** |
    | summary 行高 | 15px | 15px | 0 |
    | 卡片高 | 29px | 31px | **+2px** |

    三角盒高 8→5 未吃到行盒（`.dict-label` 是 10px 字号，行盒够高），所以位移**只**来自盒宽与内容 div 的 padding，与字体无关。
- **[x] ① 已修复** — 两处各一条最小改动，都把「随状态变化的几何」改成「恒定几何」：
  - A：展开态**只旋转不重画**——删掉 `[open]` 的四条 border 重设，改 `transform: rotate(90deg)`。transform 不参与布局，布局盒恒为 5×8，两态 `.dict-name` 左偏移恒等；同一份右向三角绕盒心旋转 90° 后的形状（底边 8、高 5）与旧展开态逐像素相同。
  - B：2px 间距的拥有者从「只在展开态存在的内容 div」改成「恒存在的卡头」——`.glossary-group > div[data-dictionary]` 去掉 `padding-top`，`.glossary-group > summary` 加 `padding-bottom: 2px`。卡片基线高度与展开状态无关，展开只增加真实内容的高度；有内容时卡头与释义之间仍是同样的 2px。
  - 修后同一套实测：**四项 delta 全为 0.000**（左偏移恒 10px、行高恒 17px、卡高恒 31px）；有真实释义的卡片高度修前修后同为 50.594px，即**有内容的卡观感逐像素不变**，只有收起态卡片随基线对齐长高 2px。另用 6× 缩放截图肉眼复核：旋转所得 `▼` 形状正确、未被卡片内边距裁剪，收起/展开两张卡的词典名左边界完全对齐。
  - 五镜像同步：真源 `fushi/assets/popup/popup.css` → `cp` 进两份 vendor `popup.css` → `node tools/browser-extension/scripts/generate-content-css.mjs` 重新生成两份 `content.css` → `node tools/browser-extension/scripts/sync-mirrors.mjs`。三份 popup.css 与两份 content.css 各自 sha256 一致。
- **[x] ② 已加自动化测试** — 加强既有守卫 `fushi/test/dictionary/popup_disclosure_triangle_guard_test.dart`（原 TODO-1337 守卫断言的正是本次删掉的 `border-top: 5px solid currentColor` / `border-bottom: 0`，若只改 CSS 不改守卫必红）：
  - 保留 TODO-1337 的两条原始不变式（禁字体字形 ▶/▼、收起态是 `border-left` 边框三角）；
  - 新增 **`[open]` 属性白名单**：只允许 `transform` / `transform-origin`，出现任何 `border-*` / `width` / `height` / `margin` / `padding` 等会改布局盒的属性即红。是白名单不是黑名单——新属性必须先想清楚会不会改盒子；
  - 新增 **间距归属**断言：`div[data-dictionary]` 不得声明 `padding-top` / `margin-top`，`.glossary-group > summary` 必须声明 `padding-bottom: 2px`；
  - 扫描面从 3 个 popup.css 扩到 **5 个**，把两份**生成的** `content.css` 一并纳入，才抓得到「改了真源忘了重新跑 generate-content-css.mjs」；
  - 规则体匹配前先 `stripComments()` 剥 `/* */`——本次修复的注释里天然出现 `padding-top` / `border-top` 字样，不剥就会把解释文字当成真声明。
  - **变异实测**（非空转证明）：把 A 改回四条 border 重设 → `+19 -1` 红；把 B 的 `padding-top: 2px` 加回内容 div → `+19 -1` 红；两次均从备份文件还原，还原后 popup.css sha256 = `395ee12d4731fb9a`，与变异前逐字节一致。守卫本身 20 例全绿。
  - 相邻守卫回归：`browser_extension_popup_parity_guard` / `popup_css_eink_guard` / `browser_extension_dict_media_mirror_guard` / `popup_pitch_noselect_guard` / `popup_mine_button_visual_guard` / `popup_glossary_overflow_wrap_guard` / `popup_cards_nav_icon_guard` / `global_lookup_popup_style_guard` 共 200 例全绿。
- **备注**：
  - 与 BUG-636 / TODO-1337 是同一处代码的**接续**而非回归：那轮解决的是「三角在某些字体下渲染不出来」（字体依赖），本轮解决的是它引入的「换朝向即换盒子」（状态相关几何）。两条不变式现在由同一个守卫一起锁。
  - 与 BUG-1923（制卡 `+` 用字形冒充图标导致光学中心偏低）同一族病理：**可见形状不该由会改变布局的载体绘制**。BUG-1923 的解法是把字形换成几何，本轮的解法是把「改盒子的几何变换」换成「不改盒子的 transform」。
  - **未在本 bug 范围内**：截图里「実用日本語表現辞典」展开后没有任何可见释义，这本身值得单独查（是该词典在此词条下真为空、还是渲染链把内容吃了）。本轮只消除了它带来的布局跳动，没有查为什么空——若确认是渲染缺陷应另开一条。
