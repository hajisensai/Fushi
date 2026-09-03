## BUG-1850 · 集成测试用恒真的选中行谓词当设置分类打开判据
- **报告**：2026-08-25（PR #978 合入 develop 前复审，非用户报告）
- **真实性**：✅ 真 bug（测试基建）。`fushi/integration_test/navigation_stability_test.dart` 的
  `_openSettingsDestination` 用
  ```dart
  await _pumpUntil(tester,
    () => find.byType(SettingsDetailPage).evaluate().isNotEmpty
          || _wideDestinationSelected(label), ...);
  ```
  当「分类打开成功」的判据，而 `_wideDestinationSelected` 只看「哪一行 `FushiListItem.selected`」。
  完整证据链：
  - `fushi/lib/src/settings/settings_home_page.dart:72-79`：`_selectedDestinationId` 为 null 时
    **无条件**落到 `destinations.first.id`；
  - `fushi/lib/src/settings/settings_schema.dart:91-92`：第一项就是 `buildAppearanceDestination()`；
  - `fushi/lib/src/settings/material_settings_renderer.dart:61`：
    `selected: destination.id == selectedDestinationId` —— **不区分窄屏/宽屏**，窄屏推栈后底下的
    列表同样把该行渲染成 `selected: true`；
  - 该 itest 的分类清单第一条正是 `t.settings_destination_appearance`。

  于是进入设置的**第一帧** `_wideDestinationSelected(appearance)` 就为真，与是否发生过导航完全
  无关。若回归导致 `activate()` 不再推详情页，`_pumpUntil` 立即满足 → `pushedDetail=false` →
  既不 `_systemBack` 也不做任何详情页断言；随后那句 `expect(find.text(label), findsWidgets)` 又靠
  左侧列表自己通过（宽屏左列表永远显示全部 13 个标题）。**外观那一轮退化成「这一行存在且能
  聚焦」。**
- **[x] ① 已修复** — 判据换成**详情面板身份**，并加「打开前目标不该已经在显示」的前置条件：
  - 分类清单从 `List<String>`（只有标签）改成 `List<({SettingsDestinationId id, String label})>`；
  - 新增 `_settingsDestinationShown(id)`：窄屏认 `SettingsDetailPage.destination.id == id`
    （`settings_detail_page.dart` 的公开 `destination` 字段），宽屏认
    `find.byKey(ValueKey<SettingsDestinationId>(id))`（`settings_home_page.dart:336` 的
    `KeyedSubtree`）。等待条件与前置条件共用同一个判据；
  - `_openSettingsDestination` 默认 `requireTransition: true`：activate 前先断言目标**不在显示**。
    单靠身份判据不够——宽屏首帧第一分类的面板本来就在，所以循环前先把选中项 priming 到清单
    最后一项；深路由用例连开同一分类两次，显式传 `requireTransition: false`（那里真正的断言是
    `find.byType(T)`，不恒真）;
  - `_wideDestinationSelected` 整个删除。
- **[x] ② 已加自动化测试** — 两层，均做过变异实测：
  1. **机制层（真 widget 行为）** `fushi/test/settings/settings_renderer_test.dart` 的
     `wide settings preselects and renders destinations.first before any navigation`：在 800×600
     （宽屏）挂真实 `SettingsHomePage`，只 `pump()` 一次、零交互，断言第一分类的
     `ValueKey<SettingsDestinationId>` 面板已在树上、且该行已 `selected` —— 把「这两个信号在首帧
     恒真」这条事实钉死，说明 itest 为什么必须 priming。变异：把
     `settings_home_page.dart:336` 的 key 换成 `const ValueKey<String>('settings_detail_pane')`
     → 该用例单独变红；按唯一锚点还原后 sha256 与改动前逐字节一致
     （`ead8c0cf2f03654b1a660e9717546e0ad97452c92559e6cc202810cc4f9c3212`）。
  2. **契约层（源码扫描）** `fushi/test/tools/itest_settings_destination_identity_guard_test.dart`：
     该 itest 起真 app，进不了 `flutter test`（真单测门只跑 `test/`），所以扫源码钉住
     「身份判据在场 / selected-row 谓词不得回来 / `requireTransition` 默认为 true」。变异三次全红：
     ①把 `requireTransition` 默认值改坏；②把 `_wideDestinationSelected` 加回来；
     ③把身份判据只留在注释里（验证 `maskComments` 真的在起作用，不是靠注释假绿）。
     还原后 sha256 与改动前一致（`18ee0570eae9ce9b272d1440017919030d8cdf65c0065f536eef4298afbd272d`）。
- **备注**：`navigation_stability_test.dart` 本身**不在任何 runner 里**，只能真机/模拟器手跑；本轮
  没有真机复跑它，改动的正确性由上面两层测试 + `flutter analyze` 保证。若哪天默认预选被改掉
  （比如宽屏首帧不再自动选中第一项），机制层用例会变红，届时 itest 里的 priming 可以撤掉。
