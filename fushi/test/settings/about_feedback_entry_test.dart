import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';

/// 「设置 · 系统与关于」里常驻一个反馈入口（反馈 45e1P7jN98 / cqx_Fv6kUY）。
///
/// 反馈中心原先只有首页工具栏和悬浮球两个入口，二者都能在设置里关掉；首页关掉时
/// 「首页入口」分区虽然补了一行，但只在首页关着时出现、位置也不好找。现在反馈行
/// 放在「通用」分区（版本 / 官网 / GitHub 那一组，即关于区），不挂任何显隐谓词，
/// 无论首页、悬浮球开关如何都在；「首页入口」分区不再重复放一行。
void main() {
  // LocaleSettings.setLocale 经 slang_flutter 碰 WidgetsBinding.instance。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  SettingsSection section(String id) => buildSystemDestination().sections
      .firstWhere((SettingsSection s) => s.id == id);

  test('关于区（通用分区）常驻一行反馈，无显隐谓词', () {
    final SettingsSection general = section('system.section.general');
    final SettingsNavigationItem feedback = general.items
        .whereType<SettingsNavigationItem>()
        .firstWhere((SettingsNavigationItem i) => i.id == 'system.feedback');

    expect(feedback.title, t.feedback_title);
    expect(feedback.onTap, isNotNull, reason: '点了要打开反馈中心');
    expect(feedback.visible, isNull, reason: '不能随首页 / 悬浮球等任何开关一起被关成不可达');
    expect(general.visible, isNull, reason: '所在分区本身也必须常驻可见');
  });

  test('反馈行挨着官网 / GitHub 这组关于项，而不是混在功能开关中间', () {
    final List<String> ids = section(
      'system.section.general',
    ).items.map((SettingsItem i) => i.id).toList();
    final int feedbackIndex = ids.indexOf('system.feedback');
    expect(feedbackIndex, isNonNegative);
    expect(ids.indexOf('system.app_version'), lessThan(feedbackIndex));
    expect(ids.indexOf('system.website'), feedbackIndex + 1);
  });

  test('整个系统分类里只有一个反馈入口（首页入口分区不再重复）', () {
    final List<SettingsItem> feedbackRows = buildSystemDestination().sections
        .expand((SettingsSection s) => s.items)
        .where((SettingsItem i) => i.title == t.feedback_title)
        .toList();
    expect(feedbackRows.map((SettingsItem i) => i.id), <String>[
      'system.feedback',
    ]);
    expect(
      section(
        'system.section.home_shortcuts',
      ).items.map((SettingsItem i) => i.id),
      isNot(contains('system.home_shortcut_feedback')),
    );
  });
}
