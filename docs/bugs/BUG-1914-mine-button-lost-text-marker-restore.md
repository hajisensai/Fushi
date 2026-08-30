## BUG-1914 · 制卡按钮被加回 inline-action-button 基类，三条 TODO-1325 还原守卫在 develop 上已红
- **报告**：2026-08-28（不是用户报的——2026-08-28 用户反馈批次做**合入前全量**时撞出来的）
- **真实性**：⚠️ **红是真的，但定性反了**——不是代码回归，是**守卫过期**。裁决：保留现状（用户 2026-08-28 拍板），改守卫。

### 症状

三条守卫同时红，同一个根因：

| 守卫 | 断言 | develop 实际 |
|---|---|---|
| `popup_niratan_visual_guard_test.dart:96` | `js.contains('inline-action-button mine-button')` **isFalse** | 含（`popup.js`） |
| `popup_niratan_visual_guard_test.dart:148` | 正则 `className: 'mine-button',\s+textContent: '\+',` | class 是 `'inline-action-button mine-button'`，正则不匹配 |
| `popup_mine_button_anki_truth_static_test.dart:39` | `indexOf("className: 'mine-button'") >= 0` | 同上，返回 -1 → `setUpAll` 直接炸掉整个 suite（6 项） |

### 根因

**报告初稿的技术论断逐条与 `popup.css` 实际内容相反**，据此写下的「回归」结论不成立。

初稿说「`inline-action-button` 是其余四类 SVG 图标按钮的共享基类……它会让制卡按钮跟着
图标按钮的尺寸/内边距走，而不是 `.mine-button` 自己那套单色符号字体栈」。查实：

| 初稿论断 | `popup.css` 实际 |
|---|---|
| 基类会带来图标按钮的**内边距** | `.inline-action-button` 规则体里**没有 padding**（只有 `display:inline-flex` / `align-items` / `justify-content` / `cursor` / `transition:opacity`） |
| 基类会带来图标按钮的**尺寸** | 尺寸规则写在 `.inline-action-button > svg`（`width/height:1em`）——制卡按钮的子节点是 `textContent` 文本，**这条选择器永不命中** |
| 基类会顶掉 `.mine-button` 的**单色符号字体栈** | `.mine-button` 的 `font-family` 带 `!important`；`font-size`（18px / `:not(.duplicate)` 30px / `.latest` 15px）、`padding: 0 4px`、`opacity` 也全由 `.mine-button` 自己定，基类根本没有同名声明可竞争 |

真正的历史顺序与「回归」相反：**BUG-932/1895 有意把基类加上去的**。`popup.css` 那段
注释写得明明白白——静息 `+` 是文本字形、只占 em 盒约一半高，相邻 audio/favorite 的
1em SVG 铺满，故用 `font-size:30px` 补偿；而**「按钮本体还必须挂 inline-action-button，
才能走同排的 inline-flex 居中与 pointer 光标」**，并留了正向守卫
`popup_mine_button_visual_guard_test.dart`（"mine button reuses clickable action
layout"，三个 JS 镜像各一条，断言 className **必须**是
`'inline-action-button mine-button'`），扩展侧另有 `popup-mine-button-visual.test.js`
同向。

三条红守卫是 TODO-1325 时期写的，把「不再走 SVG 图标」这句话固化成了「className 必须
逐字等于 `mine-button`」。BUG-1895 改设计时没有回头更新它们，于是它们与
`popup_mine_button_visual_guard_test.dart`
互相矛盾——**同一个仓库里两组守卫对同一行代码给出相反判决**，红的那一组是过期的那组。

### 修复与测试

- **[x] ① 根因修复** — 提交 `38012ceb50`（守卫侧）+ 本批 popup.js 注释消歧：
  - `popup_niratan_visual_guard_test.dart`：把 `'inline-action-button mine-button'`
    的 `isFalse` 断言改成**纳入共享基类清单**（与 `popup_mine_button_visual_guard_test.dart` 同向）；
    定位正则放宽成 `RegExp(r"className: '[^']*\bmine-button',\s+textContent: '\+',")`
    ——它仍然钉死「静息态是文本 `+` 而不是 SVG」这条**真正的** TODO-1325 不变式，只是
    不再把 class 列表的确切拼写当判据。
  - `popup_mine_button_anki_truth_static_test.dart`：块起点锚点同样换成
    `RegExp(r"className: '[^']*\bmine-button',")`，并加注释说明这里只是定位、
    别把 class 名拼写当判据。
  - `popup.js` 三镜像：在 `mineButton` 创建点补一段消歧注释，写清基类**只给布局**
    （inline-flex 居中 + pointer 光标 + hover/active/disabled 三态），它自己既没有
    padding 也没有 font-size，SVG 尺寸规则挂在 `> svg` 上永不命中本按钮——正是这句
    话缺席，才让本条被误判成回归。三镜像改后 sha256 仍逐字节相同。
- **[x] ② 自动化测试** — 覆盖**已经存在**：`popup_mine_button_visual_guard_test.dart`
  正向钉死「制卡按钮必须挂 inline-action-button」（+ 扩展侧
  `popup-mine-button-visual.test.js`），改后的 `popup_niratan_visual_guard`
  钉死「静息态必须是文本 `+`、不是 SVG」。两条现在同向，不再互相打架。缺的从来不是
  覆盖，是裁决——已由用户拍板「保留现状」。

### 备注

- **教训（守卫写法）**：`popup_niratan_visual_guard` 那条 `isFalse` 是「把当时的字面
  形状当成不变式」的典型。真不变式是「静息态是文本字形而非 SVG 图标」；className
  里多不多一个布局基类与它正交。守卫钉字面串、设计一动就红，红了还会把人引向反方向
  的结论——本条走完整个「疑似回归 → 立案 → 查 CSS → 发现定性反了」的弯路，成本全在
  这里。
- 复核方式（当时用来排除「我改红的」）：`git diff origin/develop` 对这两个测试文件均为
  **空**（逐字节相同），`origin/develop` 自己的 `popup.js` 里
  `className: 'inline-action-button mine-button'` 确实存在——两侧都验过。这一步结论本身
  没错（红确实先于本批存在），错在由此顺推出「代码回归了」。
