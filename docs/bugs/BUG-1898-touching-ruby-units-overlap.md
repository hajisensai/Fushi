## BUG-1898 · 紧邻的两个带注音基字振假名重叠：明鏡四字熟語糊成一团
- **报告**：2026-08-28（用户：「这个词典四字词语带振假名重叠了」，附截图 + `[Monolingual] 明鏡国語辞典 第三版.zip`；截图里「登場人物」的读音压成一团）
- **真实性**：✅ 真 bug，且是 **BUG-1778 引入的回归**（把 BUG-850 的修复撤掉了）。

### 根因：同一个开关被来回拨了两次

弹窗手工模拟 ruby，注音盒是绝对定位的：
`popup.css:1142` `.ruby-rt { position:absolute; left:0; right:0; white-space:nowrap; text-align:center }`
—— 盒宽恒等于基字宽，读音更长时**向两侧溢出且不撑开任何东西**。

横向避让的历史：

| | 做法 | 解决 | 引入 |
|---|---|---|---|
| BUG-850 | `.ruby-reserve` **永远 in-flow**（每个基字撑到 max(基字, 读音)） | 相邻读音不再碰 | 短基字配长读音时正文字距被拉开（体/からだ） |
| BUG-1778（2026-08-23） | 改成**永远 absolute** | 字距恢复自然 | **BUG-850 的碰撞原样回来** |
| BUG-1655 | 注音 0.5em → 0.6em | 太小的问题 | 读音再宽两成，碰得更狠 |

BUG-1778 还配了守卫测试锁死 `.ruby-reserve { position: absolute }`，把这个钟摆固定在了
「永远悬出」那一侧。

**实测数据（2026-08-28 解包 `明鏡国語辞典 第三版` 的 `term_bank_1.json` 全量扫描）**：

```
ruby elements      : 205702
adjacent ruby pairs: 7832
样本：曲学(きょくがく) + 阿世(あせい) / 阿諛(あゆ) + 追従(ついしょう) / 外国(がいこく) + 語(ご)
```

即四字熟語在该词典里是**两个独立 `<ruby>` 直接相邻**（中间没有任何普通文字），共 7832 处。
算一下 `曲学阿世`：曲学 基字 2em、读音 5 假名 × 0.6em = 3em → 每侧溢出 0.5em；
阿世 基字 2em、读音 2.4em → 每侧 0.2em；**相碰 0.7em**。用户截图里的「登場人物」同形。

### 修复与测试

- **[x] ① 已修复** — 判据下沉到正确的层：**注音悬出到普通文字上没有任何问题**（原生 ruby
  的参考行为，也正是 BUG-1778 想要的紧凑正文字距），**只有隔壁也是带注音的单元时才必须
  给出空间**（BUG-850 的真实场景）。所以横向预留不再是全局开关：
  - `popup.js` 的 `postProcessRuby` 新增 `markTouchingRubyUnits`：纯 DOM 判定「两个
    `.ruby-unit` 之间除空白外没有任何文本」，是则给两侧都打上 `.ruby-tight`。
    判定只用 `childNodes / nextSibling / parentNode / nodeType / textContent`，
    **刻意不用 Range / `:scope` / `compareDocumentPosition`** —— 行为测试的假 DOM 不提供
    它们，一旦依赖，这条逻辑就失去行为级守护（守卫测试里有反向断言锁住这点）。
  - `popup.css` 新增 `.ruby-unit.ruby-tight > .ruby-reserve { position: static }`，
    只让这些单元把孪生体放回 in-flow。默认规则仍是 `absolute`，BUG-1778 的不变量不变。
  - 两个单元互相标记是有意的：孪生体宽度是 `max-content`，读音不比基字宽时撑不开单元，
    标了等于没标 —— 省掉「到底该谁让位」的分支。
  三镜像已同步，`content.css` 已重新生成。
- **[x] ② 已加自动化测试** —
  - 行为级：`fushi/test/pages/popup_glossary_ruby_touching_units_test.js`（node 真执行
    `popup.js` 的 `postProcessRuby`）+ `..._test.dart` 驱动。8 个用例：相邻 `<ruby>` 对标记 /
    只有一侧溢出也标 / 隔着助词不标 / 纯空白仍算相邻 / 同一 `<ruby>` 内多基字（小学館
    将棋形状，BUG-722）标记 / 无注音的邻居不算碰撞对象 / 孤立宽读音不标 / 二次 pass 幂等。
    语料全部取自上面那份实测样本。
  - 源码级：CSS 必须同时具备「默认 absolute」和「`.ruby-tight` 下 static」两条规则。
  - **变异实测**（2026-08-28）：把 `rubyUnitsAreTouching` 改成恒真 → 「隔着助词不标」转红；
    改成恒假 → 「相邻对必须标」转红。两次变异均被捕获，还原后 8 项全绿、探针零残留。

### 备注

- 代价：真正相邻的那对词，基字之间会多出 ≈0.7em 的避让空隙。这是必要的——原生 CSS ruby
  在同样情形下也会撑开基字盒。不相邻的位置（绝大多数）字距完全不变。
- 未做真机复测。ruby 几何无法 headless 渲染，本轮靠「真执行 popup.js 的 DOM 断言 + CSS
  级联守卫」两层兜；建议在真机装明鏡三版肉眼确认一次四字熟語。
- 与 [BUG-1897](BUG-1897-dict-css-double-scales-ruby.md) 同批报告、同一子系统，但根因互相
  独立（那条是词典 CSS 覆盖归一化规则，这条是弹窗自身的横向几何）。
