## BUG-2240 · 词形变化标签未本地化且部分日语标签缺少说明
- **报告**：2026-09-07（用户截图：potential or passive 标签仍显示英文，部分标签没有响应）
- **真实性**：✅ 真 bug。`packages/fushi_dictionary/lib/src/language/language.dart:467` 的显示本地化只翻译 description，name 直接透传；`fushi/assets/transforms/ja.json:1` 的 imperative negative slang 说明为空，`fushi/assets/popup/popup.js:2636` 因而不注册悬停/点击事件。
- **[x] ① 已修复** — 本提交在显示边界同时翻译名称与说明，为日语全部英文变形名补齐中文译名，并补充口语禁止形的源说明与中文译文。持久化 extra 和引擎名称保留原文，切换界面语言可重新显示。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/transform_description_i18n_test.dart` 覆盖日语全部变形说明非空、英文名称翻译、日语接续形式保留、缓存原文及语言切换。
- **备注**：尚未在用户原始弹窗复测；“有些词没反应”尚无具体样例，不能把所有无响应都归因于缺说明。已固定说明时悬停其他标签不切换是现有交互，需要点击切换。
