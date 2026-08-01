## BUG-1392 · 合集三 PR 绕过 MD3 页面 chrome 守卫：CheckboxListTile / 手抄封面角标 / 硬编码 fontSize 直接把 develop 打红

- **报告**：2026-08-02（看板 TODO-2594，develop 既有红）
- **真实性**：✅ 真 bug（三处都是真违规，不是守卫误伤）。`origin/develop` `0bb1647ef` 上
  `hibiki/test/settings/md3_design_system_static_test.dart:1164`（`ordinary page chrome does not
  reopen local MD3 decisions`）实测红，三个 offender：
  - `hibiki/lib/src/media/video/cover_ui/episode_rename_confirm_dialog.dart:54,77` —— 全选行与逐集行
    裸用 `CheckboxListTile`，本仓合规写法是共享 `HibikiListItem` + 裸 `Checkbox` 作 leading
    （既有范式：`collections_page.dart:1659` / `dictionary_dialog_page.dart:825`）。
  - `hibiki/lib/src/pages/implementations/collection_split_dialog.dart:100,104` —— 成员清单
    `TextStyle(fontSize: 12)` 硬编码字号（不随 textScale）+ 同样裸用 `CheckboxListTile`。
  - `hibiki/lib/src/pages/implementations/collection_relations_section.dart:212-231,265` ——
    关系类型徽标是**第四份手抄的封面角标胶囊**（`Color(0xB8000000)` + `BorderRadius.circular(999)`
    + `fontSize: 11` 白字），而共享组件 `CoverBadge` 正是为收口这一类而建
    （其文档写明"此前同款胶囊至少复制三份且 alpha 各异"）；无封面占位
    `ColoredBox(color: cs.surfaceContainerHighest)` 也绕开了共享 `ShelfCoverPlaceholder`。

  来源是 `a328828ed` / `eaa2d4303` 两个合集 PR。守卫文件自身在 base 与 develop 无差异 ⇒ 不是谁把绿
  改红，而是**合入时没跑到这条守卫**。

- **[x] ① 已修复** —— 全部走生产代码，未加任何 allowlist 豁免（加豁免等于在该文件上整体关掉守卫）：
  - `CoverBadge.icon` 改为可空（`assert(icon != null || label != null)`），支持纯文字形态；
    `collection_relations_section` 的关系徽标改用 `CoverBadge(label: ...)`，无封面占位改用共享
    `ShelfCoverPlaceholder(backgroundColor: tokens.surfaces.overlay)`。
  - `episode_rename_confirm_dialog` / `collection_split_dialog` 的 `CheckboxListTile` 改为
    `HibikiListItem(density: compact, leading: Checkbox(...), onTap: 翻转)`，ValueKey 原样保留
    （既有 widget 测试的 `find.byKey` 点击路径不变）。
  - `collection_split_dialog` 的硬编码 12px 改为 `textTheme.bodySmall`（随 textScale 缩放）。

- **[x] ② 已加自动化测试** —— 守卫本身就是最强可落地层，三处修复由
  `hibiki/test/settings/md3_design_system_static_test.dart` 的
  `ordinary page chrome does not reopen local MD3 decisions` 直接盯住（变异实测：任一处回退即红）。
  同轮顺带修掉守卫**判据内部的子串包含**：`surfaceContainerHigh` ⊂ `surfaceContainerHighest`
  会让失败报告列出源码里根本不存在的 token（本条 bug 的原始报错就出现了这个幻影命中）。改法是给
  互为前缀的容器面色角色加**右边界**整标识符匹配，并同时把此前根本没被列进去的
  `surfaceContainerLowest` 补进 forbidden 列表——右边界只去掉重复命中，不放过任何一个角色。
  禁止列表与"要求使用的共享组件"之间**无未防护的子串包含**：`Card(` ⊂ `HibikiCard(`、
  `ListTile(` ⊂ `HibikiListTile(`/`CheckboxListTile(` 已由 `_identifierCallTokens` 的左边界正则
  + `_withoutSharedComponentNames` 改名双重防护（变异实测：把 `HibikiCard(` / `HibikiListTile(`
  塞进非豁免文件，守卫仍绿，不会在"改对那一刻"炸）。

- **备注**：纯静态守卫 + 共享组件替换，无 reader/WebView/导入/播放路径改动。视觉侧唯一可感知差异是
  关系徽标胶囊从手抄规格（圆角 999 / alpha 0.72 / 11px w600）统一到 `CoverBadge` 规格
  （圆角 10 / alpha 0.6 / labelSmall），这正是该组件要收口的方向。
