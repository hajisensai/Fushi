import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// `integration_test/navigation_stability_test.dart` 的「打开每个设置分类」用例
/// 曾经用「这一行被高亮」当打开成功的判据：
///
/// ```dart
/// await _pumpUntil(tester,
///   () => find.byType(SettingsDetailPage).evaluate().isNotEmpty
///         || _wideDestinationSelected(label), ...);
/// ```
///
/// 这在宽屏第一帧就恒真——`settings_home_page.dart` 在 `_selectedDestinationId`
/// 为 null 时无条件落到 `destinations.first.id`（= 外观），
/// `material_settings_renderer.dart` 的 `selected:` 又不区分窄/宽屏。于是外观那
/// 一轮 `activate()` 就算完全不做事，`_pumpUntil` 也立刻满足、`pushedDetail` 为
/// false、既不 `_systemBack` 也不做任何详情页断言，整条退化成「这一行存在且能
/// 聚焦」。机制侧的证据锁在
/// `test/settings/settings_renderer_test.dart` 的
/// 「wide settings preselects and renders destinations.first ...」。
///
/// 该 itest 起真 app，进不了 `flutter test`（真单测门只跑 `test/`），所以用源码
/// 扫描把两条契约钉住：
///   ① 判据必须是**详情面板身份**（`SettingsDetailPage.destination.id` /
///      `ValueKey<SettingsDestinationId>`），不得再出现「selected 行」谓词；
///   ② 必须有「打开前目标不该已经在显示」的前置条件，否则身份判据在宽屏首帧
///      对第一分类同样恒真。
void main() {
  final File itest =
      File('integration_test/navigation_stability_test.dart');

  test('the navigation-stability itest exists where the guard expects it', () {
    expect(
      itest.existsSync(),
      isTrue,
      reason: '守卫的扫描目标不在了；文件被挪走/改名时必须同步改这里，'
          '否则守卫会静默变成零断言',
    );
  });

  test('settings destinations are asserted by detail-pane identity', () {
    final String code = maskComments(itest.readAsStringSync());

    // ① 身份判据必须在场。
    expect(
      code,
      contains('widget is SettingsDetailPage && widget.destination.id == id'),
      reason: '窄屏必须按推栈详情页自带的 destination.id 判身份',
    );
    expect(
      code,
      contains('find.byKey(ValueKey<SettingsDestinationId>(id))'),
      reason: '宽屏必须按详情面板的 ValueKey<SettingsDestinationId> 判身份',
    );

    // ② 「哪一行高亮」谓词不得作为导航证据回来。
    expect(
      code,
      isNot(contains('widget is FushiListItem && widget.selected')),
      reason: '「这一行被高亮」在宽屏首帧恒真，不构成导航证据（PR #978 复审）',
    );
    expect(
      code,
      isNot(contains('_wideDestinationSelected')),
      reason: '恒真的 selected-row 判据不得以任何名字回来',
    );
  });

  test('opening a destination requires a real transition by default', () {
    final String code = maskComments(itest.readAsStringSync());

    // 前置条件本体：默认要求目标「打开前不在显示」。
    expect(
      code,
      contains('bool requireTransition = true'),
      reason: '打开分类的默认契约必须是「必须真的切过去」',
    );
    expect(
      code,
      contains('_settingsDestinationShown(destination.id)'),
      reason: '前置条件与完成条件必须共用同一个身份判据',
    );

    // 宽屏下第一分类默认就被选中，所以循环前必须先把选中项挪走，
    // 否则第一条的前置条件会直接失败（而不是悄悄放过）。
    expect(
      code,
      contains('requireTransition: false'),
      reason: '循环前的 priming（以及连开同一分类的深路由）必须显式豁免，'
          '而不是把前置条件整条删掉',
    );
  });
}
