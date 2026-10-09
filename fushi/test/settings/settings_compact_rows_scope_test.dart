// 设置行紧凑档（SettingsCompactRowsScope，视频播放器设置面板的手机档）：
// 反馈 nGxUGtYot9「文字小点，附加说明简洁点或者塞角落里」+ 协调方复核
// after_phone_portrait_playback.png：YouTube 画质行「标题 + 三行说明 + 带同名标签的
// 整行下拉」重复又啰嗦。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

const String _longHint =
    '起播自动选不超过目标的最高档；「自动」优先流畅（硬解友好编码，最高 1080p），'
    '要 2K / 4K 请选 1440p / 2160p';

Widget _host(Widget row, {required bool compact}) {
  final Widget body = SizedBox(
    width: 352,
    child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[row]),
  );
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: compact ? SettingsCompactRowsScope(child: body) : body,
      ),
    ),
  );
}

AdaptiveSettingsPickerRow<int> _picker() => AdaptiveSettingsPickerRow<int>(
  title: 'YouTube 画质',
  subtitle: _longHint,
  controlBelow: true,
  selected: 0,
  onChanged: (_) {},
  options: const <AdaptiveSettingsPickerOption<int>>[
    AdaptiveSettingsPickerOption<int>(value: 0, label: '自动'),
    AdaptiveSettingsPickerOption<int>(value: 1080, label: '1080p'),
    AdaptiveSettingsPickerOption<int>(value: 2160, label: '2160p'),
  ],
);

void main() {
  testWidgets('compact: dropdown sits on the title row without a duplicate '
      'label; long hint is one line plus an info tip', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_picker(), compact: true));
    await tester.pump();

    expect(
      find.byType(GamepadMenuDropdown<int>),
      findsNothing,
      reason: '紧凑档不再是带同名浮动标签的整块下拉框',
    );
    final Finder compactValue = find.byKey(
      const ValueKey<String>('settings-picker-compact'),
    );
    expect(compactValue, findsOneWidget);
    expect(
      find.descendant(of: compactValue, matching: find.text('自动')),
      findsOneWidget,
      reason: '行尾直接显示当前值',
    );
    final double titleY = tester.getCenter(find.text('YouTube 画质')).dy;
    final Rect valueRect = tester.getRect(compactValue);
    expect(valueRect.top, lessThan(titleY), reason: '值与标题同一行（右侧），不再独占标题下方一整行');
    expect(valueRect.right, greaterThan(300), reason: '值靠右');

    final RenderParagraph hint = tester.renderObject<RenderParagraph>(
      find.text(_longHint),
    );
    expect(hint.maxLines, 1, reason: '说明最多一行');
    expect(
      find.byKey(const ValueKey<String>('settings-row-info')),
      findsOneWidget,
      reason: '一行放不下的说明整段收进 ⓘ 提示',
    );
  });

  testWidgets('compact: tapping the value opens the option menu', (
    WidgetTester tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      _host(
        AdaptiveSettingsPickerRow<int>(
          title: 'YouTube 画质',
          selected: 0,
          onChanged: (int v) => picked = v,
          options: const <AdaptiveSettingsPickerOption<int>>[
            AdaptiveSettingsPickerOption<int>(value: 0, label: '自动'),
            AdaptiveSettingsPickerOption<int>(value: 2160, label: '2160p'),
          ],
        ),
        compact: true,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('settings-picker-compact')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('2160p').last);
    await tester.pumpAndSettle();
    expect(picked, 2160);
  });

  testWidgets('compact: short hint needs no info tip', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AdaptiveSettingsSwitchRow(
          title: '自动连播',
          subtitle: '播完自动下一集',
          value: true,
          onChanged: (_) {},
        ),
        compact: true,
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('settings-row-info')),
      findsNothing,
    );
  });

  testWidgets('compact rows are shorter than regular rows', (
    WidgetTester tester,
  ) async {
    Future<double> height({required bool compact}) async {
      await tester.pumpWidget(
        _host(
          AdaptiveSettingsSwitchRow(
            title: '自动连播',
            subtitle: '播完自动下一集',
            value: true,
            onChanged: (_) {},
          ),
          compact: compact,
        ),
      );
      await tester.pump();
      return tester.getSize(find.byType(AdaptiveSettingsSwitchRow)).height;
    }

    final double regular = await height(compact: false);
    final double compact = await height(compact: true);
    expect(compact, lessThan(regular));
  });

  testWidgets('regular (no scope) keeps the full-width labelled dropdown', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_picker(), compact: false));
    await tester.pump();
    final GamepadMenuDropdown<int> dropdown = tester
        .widget<GamepadMenuDropdown<int>>(
          find.byType(GamepadMenuDropdown<int>),
        );
    expect(dropdown.label, 'YouTube 画质');
    expect(
      find.byKey(const ValueKey<String>('settings-row-info')),
      findsNothing,
    );
  });
}
