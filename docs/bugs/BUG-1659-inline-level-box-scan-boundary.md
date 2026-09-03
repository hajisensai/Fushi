## BUG-1659 · 查词浮窗 glossary 里带振假名的词只能查到第一个汉字
- **报告**：2026-08-15（用户：CI 巡检发现，非用户报告）
- **真实性**：✅ 真 bug（`fushi/assets/popup/selection.js:36` 的 `isInlineBox`，
  由 BUG-1645 的 `b705e79816` 引入）。
  症状两条，同一个根因：
  1. **真实浏览器**：查词浮窗 glossary 里任何带振假名的词，跨节点续扫扫到第一个
     ruby 单元就断 —— 「打ち合わせ」只取到「打」。popup.css:964
     `.ruby-unit { display: inline-block }`（postProcessRuby 给每个振假名基字包一
     个单元盒），而 `isInlineBox` 只认 `display === 'inline'`，把 inline-block 判成
     了渲染断点。
  2. **CI**：`test/js/popup_ruby_selection.test.mjs` 的
     「mixed kanji/kana lookup skips ruby-reserve layout text」在 develop 上恒红
     （`'打' !== '打ち合わせ'`）。这条走的是另一条路径 —— jsdom 默认样式表只给块级
     元素赋 display，fixture 里 span/ruby 的 computed display 全是空串，
     `isInlineBox` 的兜底只挡了 style 对象为空、没挡 display 为空串。
- **为什么 push 门没拦住**：跑这条 JS 测试的是 `main.yml`（Build Android APK），
  TODO-1208 之后**只在 pull_request 触发**。于是它红在 develop 上没人看见，却把
  当时每一个 PR 的 `build` 检查一起拖红（#850 / #851 实测）。
- **[x] ① 已修复** — `isInlineBox` 改为按「inline-level 盒」这个概念判定：
  `display.startsWith('inline') || display === 'contents' ||
  display.startsWith('ruby')`，并补 `if (!display) return true` 让空 display 落回
  既有的「拿不到样式就沿用旧续扫行为」兜底。三份 selection.js 镜像同步（逐字节
  sha256 一致）。教训是判据不要枚举概念的某个子集 —— inline-flex / inline-grid /
  inline-table 当初也一起漏了。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/nested_latin_lookup_bug1645_test.js`
  场景 E（`.ruby-unit` = `inline-block` 必须继续续扫）与场景 F（空 display 不得判成
  断点）。挑这份 harness 是因为它的 fake DOM 由测试显式指定 `display`，能钉住
  **真实浏览器**的值；`popup_ruby_selection.test.mjs` 受 jsdom 默认样式表所限只能
  盖到场景 F，盖不住 inline-block。变异实测：判据缩回 `=== 'inline'` → 场景 E 红成
  `'打' !== '打ち合わせ'`；摘掉空 display 兜底 → 场景 F 红成 `'打ち' !== '打ち合わせ'`。
- **备注**：BUG-1645 的四个原场景（相邻释义断开 / compact `::after` 分隔符断开 /
  行内拆词仍能拼回 / 日语不回归）全部不受影响 —— 它们用的是 `list-item` 与
  `inline`，与本次放宽的 inline-level 集合不相交。
