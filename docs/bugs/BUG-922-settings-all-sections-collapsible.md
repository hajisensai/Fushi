## BUG-922 · 设置所有带标题分区都应可折叠，默认展开/收起互不影响
- **报告**：2026-07-19（用户：）
- **真实性**：✅ 真 bug（能力缺失）。根因 `hibiki/lib/src/settings/settings_schema_widgets.dart:55`：折叠「能力」被和「默认收起」耦合进同一个 `collapsedByDefault` 字段——`collapsible = section.collapsedByDefault && (title 非空)`。结果只有声明 `collapsedByDefault: true` 的 17 组才长折叠头，其余带标题分区一律平铺、没有折叠箭头。所有分区本就走同一个 `SettingsSchemaSection` → `AdaptiveSettingsSection` 封装，不是特判排除也不是另一套渲染路径，纯粹是判据把两件事绑死了。
- **[x] ① 已修复** — `settings_schema_widgets.dart:55` 解耦：`collapsible = section.title?.isNotEmpty ?? false`（折叠能力只看有无标题）；`initiallyExpanded`（:64-66）继续用 `collapsedByDefault` 决定默认展开/收起。所有带标题分区都获得折叠头，各自默认态互不影响，正好对应诉求「都能折叠，某些默认折叠某些不是」。无标题分区（如 interconnect 指引组）没有可点的头，仍平铺，符合既有设计。commit: 见下
- **[x] ② 已加自动化测试** — `hibiki/test/settings/settings_renderer_test.dart`「BUG-922: every titled section is collapsible…」：构造「有标题+默认展开」「有标题+默认收起」「无标题」三分区，关掉 `debugSettingsForceExpandAllSections` 后断言：折叠头恰好 2 个（两带标题分区，无标题不出）、默认展开组的行入树、默认收起组的行不入树、无标题组的行始终平铺可见。旧耦合判据下「默认展开组」不会长折叠头，`findsNWidgets(2)` 必失败。
- **备注**：折叠态目前纯内存（`AdaptiveSettingsSection` state），不跨页面持久化；若产品要「记住每组展开/收起」需另加 pref/provider，超出本次范围。
