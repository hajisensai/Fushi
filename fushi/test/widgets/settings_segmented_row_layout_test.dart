// 设置页「分段选择行」与其它设置行是同一种行（2026-11-20 用户反馈「很违和」）：
// 标题 + 说明在卡片内左侧，分段在右侧；窄屏 / 选项多时分段换到标题下方并
// 撑满整行；任何宽度下都不出现「分段只占左边一小块、右边空着」。MD3 与 Apple
// （玻璃）两套设计系统都钉住。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

const String _downloadTitle = '下载引擎';
const String _embeddedHint = '推荐。下载在 Fushi 内部完成，无需另外安装软件。';
const String _qbHint = '连接到你已经在运行的 qBittorrent WebUI。';

const List<ButtonSegment<String>> _downloadSegments = <ButtonSegment<String>>[
  ButtonSegment<String>(value: 'embedded', label: Text('内置引擎')),
  ButtonSegment<String>(value: 'qb', label: Text('外接 qBittorrent')),
  ButtonSegment<String>(value: 'host', label: Text('互联设备')),
];

const List<ButtonSegment<String>> _targetSegments = <ButtonSegment<String>>[
  ButtonSegment<String>(value: 'srs', label: Text('Fushi 复习')),
  ButtonSegment<String>(value: 'anki', label: Text('Anki')),
];

/// 行左右内边距（MD3 rowHorizontal / Apple 行内边距同为 16）。
const double _inset = 16;

class _Host extends StatefulWidget {
  const _Host({required this.segments});
  final List<ButtonSegment<String>> segments;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String value = widget.segments.first.value;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsSection(
      children: <Widget>[
        AdaptiveSettingsSegmentedRow<String>(
          key: const ValueKey<String>('row'),
          title: _downloadTitle,
          subtitle: value == 'qb' ? _qbHint : _embeddedHint,
          segments: widget.segments,
          selected: value,
          onChanged: (String v) => setState(() => value = v),
        ),
      ],
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required bool apple,
  List<ButtonSegment<String>> segments = _downloadSegments,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
    textTheme: Typography.material2021().black,
    glassDesign: apple,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(platform: TargetPlatform.android),
      home: FushiGlassScope(
        child: Scaffold(
          body: SingleChildScrollView(child: _Host(segments: segments)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final Finder _row = find.byKey(const ValueKey<String>('row'));

/// 行里渲染出来的分段控件（MD3 胶囊分段是 SegmentedButton 子类；Apple 是
/// FushiSegmentedButton）。菜单形态下不存在。
Finder _strip() => find
    .descendant(
      of: _row,
      matching: find.byWidgetPredicate(
        (Widget w) => w is SegmentedButton || w is FushiSegmentedButton,
      ),
    )
    .first;

void main() {
  for (final bool apple in <bool>[false, true]) {
    final String design = apple ? 'Apple' : 'MD3';

    for (final double width in <double>[1100, 600, 360]) {
      for (final (String name, List<ButtonSegment<String>> segs)
          in <(String, List<ButtonSegment<String>>)>[
            ('下载引擎（3 段）', _downloadSegments),
            ('卡片去向（2 段）', _targetSegments),
          ]) {
        testWidgets('$design $width $name：说明在卡片内、分段贴右缘不留半张空卡', (
          WidgetTester tester,
        ) async {
          await _pump(tester, width: width, apple: apple, segments: segs);
          expect(tester.takeException(), isNull);

          final Rect row = tester.getRect(_row);
          final Rect title = tester.getRect(find.text(_downloadTitle));
          final Rect hint = tester.getRect(find.text(_embeddedHint));

          // 说明在卡片（行）里，紧跟标题下方，不再掉到卡片外。
          expect(row.contains(hint.topLeft), isTrue, reason: '说明的左上角在行内');
          expect(row.bottom, greaterThanOrEqualTo(hint.bottom - 0.5));
          expect(hint.top, greaterThanOrEqualTo(title.bottom - 0.5));
          expect(title.left, moreOrLessEquals(row.left + _inset, epsilon: 1));

          final Rect strip = tester.getRect(_strip());
          // 分段控件不越出行（不溢出），且右缘贴着行的右内边距：要么行内靠右，
          // 要么下方撑满——两种都不会让卡片右侧大半空着。
          expect(strip.left, greaterThanOrEqualTo(row.left + _inset - 0.5));
          expect(
            strip.right,
            moreOrLessEquals(row.right - _inset, epsilon: 1),
            reason: '分段右缘必须贴行右内边距（$strip in $row）',
          );

          if (strip.top >= hint.bottom - 0.5) {
            // 下方形态：从左内边距撑到右内边距，整行铺满。
            expect(
              strip.width,
              moreOrLessEquals(row.width - 2 * _inset, epsilon: 1),
              reason: '下方形态的分段必须撑满整行',
            );
          } else {
            // 行内形态：在标题 / 说明右侧，标题列不被挤没。
            expect(strip.left, greaterThan(title.left + 100));
            expect(strip.left, greaterThanOrEqualTo(hint.right - 0.5));
          }
        });
      }
    }

    testWidgets('$design 360 宽：3 段换到标题下方并撑满，不溢出', (WidgetTester tester) async {
      await _pump(tester, width: 360, apple: apple);
      expect(tester.takeException(), isNull);
      final Rect row = tester.getRect(_row);
      final Rect hint = tester.getRect(find.text(_embeddedHint));
      final Rect strip = tester.getRect(_strip());
      expect(strip.top, greaterThanOrEqualTo(hint.bottom - 0.5));
      expect(strip.width, moreOrLessEquals(row.width - 2 * _inset, epsilon: 1));
      expect(row.bottom, greaterThanOrEqualTo(strip.bottom));
    });

    testWidgets('$design 1100 宽：2 段在标题右侧（行内）', (WidgetTester tester) async {
      await _pump(tester, width: 1100, apple: apple, segments: _targetSegments);
      final Rect hint = tester.getRect(find.text(_embeddedHint));
      final Rect strip = tester.getRect(_strip());
      expect(strip.top, lessThan(hint.bottom));
      expect(strip.left, greaterThan(hint.right));
    });

    testWidgets('$design 切换选中项：说明在卡内交叉淡化，时长取 FushiMotion.medium', (
      WidgetTester tester,
    ) async {
      await _pump(tester, width: 1100, apple: apple);
      await tester.tap(
        find.descendant(of: _row, matching: find.text('外接 qBittorrent')),
      );
      await tester.pump();
      await tester.pump(FushiMotion.medium ~/ 2);
      // 过渡中：新旧说明同时在场（旧的淡出、新的淡入），都在行内。
      expect(find.text(_embeddedHint), findsOneWidget);
      expect(find.text(_qbHint), findsOneWidget);
      final Rect row = tester.getRect(_row);
      expect(row.contains(tester.getRect(find.text(_qbHint)).topLeft), isTrue);
      await tester.pump(FushiMotion.medium);
      await tester.pumpAndSettle();
      expect(find.text(_embeddedHint), findsNothing);
      expect(find.text(_qbHint), findsOneWidget);
    });
  }

  group('settingsSegmentedPlacement 判据', () {
    test('窄而短：行内', () {
      expect(
        settingsSegmentedPlacement(
          labelCount: 2,
          inlineWidth: 200,
          minContentWidth: 150,
          rowWidth: 800,
          rowInset: 16,
        ),
        SettingsSegmentedPlacement.inline,
      );
    });
    test('行内放不下但整行放得下：下方', () {
      expect(
        settingsSegmentedPlacement(
          labelCount: 3,
          inlineWidth: 400,
          minContentWidth: 300,
          rowWidth: 360,
          rowInset: 16,
        ),
        SettingsSegmentedPlacement.below,
      );
    });
    test('选项多于 4 个：即使宽也不放行内，放下方', () {
      expect(
        settingsSegmentedPlacement(
          labelCount: 6,
          inlineWidth: 300,
          minContentWidth: 300,
          rowWidth: 1200,
          rowInset: 16,
        ),
        SettingsSegmentedPlacement.below,
      );
    });
    test('整行都放不下每段文字：菜单', () {
      expect(
        settingsSegmentedPlacement(
          labelCount: 4,
          inlineWidth: 600,
          minContentWidth: 500,
          rowWidth: 360,
          rowInset: 16,
        ),
        SettingsSegmentedPlacement.menu,
      );
    });
  });
}
