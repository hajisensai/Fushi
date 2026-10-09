## BUG-3088 · もらうた 被推断成 もらう + 关西方言 -た
- **报告**：2026-10-09（用户截图：「誓ってもらうため」点「も」查出 もらう，标签「-た」«「关西方言」，高亮 もらうた）
- **真实性**：❌ 未复现为 Fushi 缺陷——与 Yomitan 行为一致。规则来自 `fushi/assets/transforms/ja.json` 的
  `kansai-ben -た`：`うた → った`（再经 `-た` 的 `った → う` 回到 もらう），与 Yomitan 上游
  `ext/js/language/ja/japanese-transforms.js` 的 `suffixInflection('うた', 'った', ['-た'], ['-た'])` 逐字相同（用于 思うた / 言うた 等）。
  Yomitan `translator.js` `_findTermsInternal` 同一词条按 transformedText **最长**者保留，所以 Yomitan 对「もらうため」同样给出
  もらう〔-た « 関西弁〕并高亮 4 字。这是方言变形规则在标准语文本里的歧义，不是规则写错。
- **[ ] ① 未修复** — 是否降权方言变形（例如：较短的无变形匹配存在时不让仅经 kansai-ben 的更长匹配胜出）或提供关闭方言变形的开关，属于偏离 Yomitan 的产品取舍，待所有者决定。
- **[ ] ② 未加自动化测试** — 同上，待定方案后再加。
- **备注**：
