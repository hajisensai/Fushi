## BUG-1897 · 词典自带 rt 字号与注音盒相乘，小学館十二版振假名只剩 0.3em
- **报告**：2026-08-28（用户：「小学館12 怎么振假名这么小」，附 `[JA-JA] 小学館例解学習国語 第十二版[2025-08-18].zip`）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/popup.css:1178`（归一化规则特异度不足）。

### 根因：双重缩放，不是尺寸被调小

查词弹窗不用原生 ruby，而是把它拆成 `.ruby-unit > .ruby-rt > rt` 三层手工模拟
（BUG-1487：WebKit 在渲染器层把 `<rt>` 的 `position` 强制重置成 static，绝对定位盒
只能是中性 `<span>`）。振假名尺寸的**唯一承担者**是 `.ruby-rt` 这个盒：

- `popup.css:1142` `.ruby-rt { font-size: 0.6em }`（BUG-1655 从 0.5em 调上来）
- `popup.css:1178` `.ruby-rt rt { font-size: 1em }` —— 把内层 `<rt>` 归一化，防止再缩一次

而词典 zip 自带的 `styles.css` 会被 `constructDictCss`（`fushi/assets/popup/dict-media.js:38`）
逐规则加上 `[data-dictionary="<词典名>"]` 前缀，再作为 `<style>` 追加进该词典的
dictWrapper **内部**（`popup.js:3630`）。于是词典里一条**裸**的 `rt { font-size: 0.5em }`
变成 `[data-dictionary="X"] rt { font-size: 0.5em }`：

| 规则 | 特异度 | 位置 |
|---|---|---|
| `:where(…) .ruby-rt rt { font-size: 1em }` | (0,1,1) | popup.css，靠前 |
| `[data-dictionary="X"] rt { font-size: 0.5em }` | (0,1,1) | 词典 style，靠后 |

**打平 → 后者靠文档顺序赢**。净结果 `0.6em × 0.5 = 0.3em`：15px 的释义正文下振假名只有
**4.5px**。

实测证据（2026-08-28 直接解包该词典）：其 `styles.css` 第 328 行正是
`rt { font-size: 0.5em; font-weight: normal; }`，另有 `rt[data-sc-small] { font-size: 0.4em }`。

**对照组自证**：同一批报告里的「明鏡国語辞典 第三版」不设裸 `rt` 字号（只有一条
`span[data-sc-rt]`，选择器命不中 `<rt>` 元素），所以明鏡的振假名不小 —— 正好对上用户
「小学館小、明鏡不小」的区分。

### 修复与测试

- **[x] ① 已修复** — `popup.css:1178` 的归一化声明改为 `font-size: 1em !important`。
  这不是保险丝而是必需：`!important` 是唯一能稳定压过「词典任意选择器 + 任意特异度」
  的手段（靠堆特异度只能赢 `rt`，赢不了 `.cls rt`）。
  定性依据：**振假名几何归弹窗所有**。词典作者写 `rt` 字号时假设的是原生 ruby（字号只
  作用一次），在这套三层模拟下没有正确语义。`rt` 的颜色 / 字重 / 字体等非几何声明不受
  影响，仍照常生效；用户自定义的 `.ruby-rt { font-size: X em !important }`（词典样式
  可视化编辑器，`dict_style_rules.dart:64` 把「振假名」部位映射到 `.ruby-rt`）作用在
  外层盒上，与本条不冲突，仍可调。
  三镜像（`fushi/assets/popup/`、`fushi/assets/browser_extension/vendor/`、
  `tools/browser-extension/vendor/`）已同步，`content.css` 已用
  `tools/browser-extension/scripts/generate-content-css.mjs` 重新生成。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dict_css_cannot_shrink_ruby_test.dart`
  锁「`.ruby-rt rt` 的值必须是 1em 且必须带 `!important`」。
  同时更新既有守卫 `fushi/test/pages/popup_ruby_single_scale_guard_test.dart`：它原先用
  `^(1em|inherit)$` 字面匹配，加了 `!important` 后认不出来会误报「缩放施加了两次」；
  改成允许可选的 `!important`（只改层叠权重、不改值，且严格更强）。

### 备注

- 副作用：词典若用 `rt[data-sc-small]` 之类做「更小的注音」语义区分，该区分会一起丢失。
  这是有意取舍——可读性优先于词典的相对字号意图。
- 未做真机复测。ruby 几何无法 headless 渲染（`popup_ruby_single_scale_guard_test.dart`
  文件头记录了 BUG-1655 调查里一个截片段探针「测出 6.5px、可信但完全错误」的教训），
  本轮只在 CSS 级联层守契约；建议在真机装该词典肉眼确认一次。
