## BUG-1914 · 制卡按钮被加回 inline-action-button 基类，三条 TODO-1325 还原守卫在 develop 上已红
- **报告**：2026-08-28（不是用户报的——2026-08-28 用户反馈批次做**合入前全量**时撞出来的）
- **真实性**：✅ 真回归，**且与本批改动无关**：在 `origin/develop` 上就已经红。

### 症状

三条守卫同时红，同一个根因：

| 守卫 | 断言 | develop 实际 |
|---|---|---|
| `popup_niratan_visual_guard_test.dart:96` | `js.contains('inline-action-button mine-button')` **isFalse** | 含（`popup.js:3022`） |
| `popup_niratan_visual_guard_test.dart:148` | 正则 `className: 'mine-button',\s+textContent: '\+',` | class 是 `'inline-action-button mine-button'`，正则不匹配 |
| `popup_mine_button_anki_truth_static_test.dart:39` | `indexOf("className: 'mine-button'") >= 0` | 同上，返回 -1 → `setUpAll` 直接炸掉整个 suite（6 项） |

### 根因

TODO-1325 曾把制卡按钮从 SVG 图标**还原**成 ✓✓↩ 文本标记（应用户要求），
TODO-1338 又给 ↩ 加了 VS15。`popup.js` 里那段注释至今还写着：

> TODO-1325 还原：应用户要求，制卡按钮回到 ✓✓↩ 文本标记（+ 可制卡 / ✓ 已制卡 /
> ✓↩ 最新可改），**不再走 SVG 图标**（audio/favorite 等其余按钮保留 SVG）。

而 `popup.js` 现在写的是：

```js
const mineButton = el('button', {
    className: 'inline-action-button mine-button',
    textContent: '+',
```

`inline-action-button` 是**其余四类 SVG 图标按钮的共享基类**（`popup.css` 里带
hover/active/disabled 三态与 SVG 尺寸规则）。给一个文本标记按钮挂上它，正是那三条
守卫要防的事——它会让制卡按钮跟着图标按钮的尺寸/内边距走，而不是 `.mine-button`
自己那套单色符号字体栈。

### 为什么本批不修

- **不属本批范围**：用户 2026-08-28 那 14 条里没有这一条。
- **这是可见的视觉决策**：TODO-1325 的还原本身就是「应用户要求」做的，要不要再撤回
  基类应当由维护者/用户拍板，而不是我为了让分支变绿顺手改掉。
- 期间我一度把 `popup_mine_button_anki_truth_static_test` 的锚点改成迁就现状
  （`indexOf("mine-button'")`），**已撤回**：那等于把守卫改成迎合跑偏的代码，
  正好掩盖掉本条。守卫是对的，红得有道理。

### 修复与测试

- **[ ] ① 未修复** — 两条可选路径，需要拍板：
  ① 若还原仍是当前设计：从 `popup.js` 的 mineButton className 里去掉
     `inline-action-button `（三条守卫随即全绿），并检查 `.mine-button` 的 CSS 是否
     自带了 hover/disabled 态（基类拿掉后不能没有）；
  ② 若共享基类是新的有意决策：更新那三条守卫，并把 `popup.js` 里 TODO-1325 那段
     已经与代码矛盾的注释一并改掉。
- **[ ] ② 未加自动化测试** — 守卫**已经存在且已在报警**（三条），本条缺的不是覆盖，
  是裁决。

### 备注

- 复核方式（避免误判成「我改红的」）：`git diff origin/develop` 对这两个测试文件均为
  **空**（逐字节相同），而 `origin/develop` 自己的 `popup.js` 里
  `className: 'inline-action-button mine-button'` 确实存在——两侧都验过。
- 本批对 `popup.js` 的改动只在 4 个块（`parseMineResult`、`createEntryHeader` 的失败
  分支、两处 ruby），都不碰 mineButton 的 className / textContent。
