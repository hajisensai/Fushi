// Cupertino（Apple）主题下不混 M3E 部件（用户 2026-11-24「material 就是
// material，cupertino 就是 cupertino」）：播放器公共件（进度条 / 传输键组 /
// 背景）、日期时间选择、缩略图播放角标在 Apple 下走各自的 Apple 分支，M3E 下
// 保持原样。判据唯一是主题（isGlassDesign），与平台无关——这里在 Android 平台
// 上跑 Apple 主题。
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoDatePicker;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_date_time_picker.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_thumbnail_play_badge.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiButtonGroup;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

final ColorScheme _scheme = ColorScheme.fromSeed(seedColor: Colors.teal);

Widget _app(Widget body, {required bool glass}) {
  final ThemeData theme = buildFushiThemeData(
    scheme: _scheme,
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: glass,
  ).copyWith(platform: TargetPlatform.android);
  return MaterialApp(
    theme: theme,
    home: FushiGlassScope(child: Scaffold(body: body)),
  );
}

class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(seconds: 30);

  @override
  Duration get duration => const Duration(minutes: 2);
}

Widget _seekBar() => Center(
  child: SizedBox(
    width: 300,
    child: FushiWavySeekBar(
      clock: _Clock(),
      isPlaying: true,
      onSeek: (_) {},
      strokeWidth: 4,
      barHeight: 20,
    ),
  ),
);

Widget _transport() => Center(
  child: FushiTransportGroup(
    isPlaying: false,
    onPlayPause: () {},
    onPrevious: () {},
    onNext: () {},
    playSize: 64,
    sideSize: ButtonSizeVariant.medium,
    sideWidth: IconButtonWidthVariant.standard,
    onSeekRelative: (_) {},
  ),
);

void main() {
  testWidgets('进度条：Apple 是细直线（无波浪画家），M3E 仍是波浪', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_seekBar(), glass: true));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const ValueKey<String>('fushi-seek-apple-track')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(FushiWavySeekBar),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
    expect(find.text('0:30'), findsOneWidget);

    await tester.pumpWidget(_app(_seekBar(), glass: false));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const ValueKey<String>('fushi-seek-apple-track')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(FushiWavySeekBar),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('传输键组：Apple 无 M3E 按钮组 / 饼干播放键，M3E 不变', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(_transport(), glass: true));
    expect(find.byType(FushiButtonGroup), findsNothing);
    expect(find.byType(FushiExpressivePlayButton), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('fushi-transport-play-pause')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('lyrics_seek_back_button')),
      findsOneWidget,
    );

    await tester.pumpWidget(_app(_transport(), glass: false));
    expect(find.byType(FushiButtonGroup), findsOneWidget);
    expect(find.byType(FushiExpressivePlayButton), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fushi-transport-play-pause')),
      findsNothing,
    );
  });

  testWidgets('背景：Apple 是静态渐变，M3E 仍是 mesh 画家', (WidgetTester tester) async {
    await tester.pumpWidget(_app(const FushiMeshBackdrop(), glass: true));
    expect(
      find.byKey(const ValueKey<String>('fushi-mesh-backdrop-apple')),
      findsOneWidget,
    );
    await tester.pumpWidget(
      _app(const FushiMeshBackdrop(animate: false), glass: false),
    );
    expect(
      find.byKey(const ValueKey<String>('fushi-mesh-backdrop-apple')),
      findsNothing,
    );
  });

  testWidgets('缩略图播放角标：Apple 不出 CircleAvatar，M3E 是 CircleAvatar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(const Center(child: FushiThumbnailPlayBadge()), glass: true),
    );
    expect(find.byType(CircleAvatar), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('fushi-thumbnail-play-badge-apple')),
      findsOneWidget,
    );
    await tester.pumpWidget(
      _app(const Center(child: FushiThumbnailPlayBadge()), glass: false),
    );
    expect(find.byType(CircleAvatar), findsOneWidget);
  });

  Future<DateTime?> openDate(WidgetTester tester, {required bool glass}) async {
    DateTime? result;
    bool done = false;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              result = await showFushiDatePicker(
                context: context,
                initialDate: DateTime(2026, 3, 10),
                firstDate: DateTime(2020),
                lastDate: DateTime(2026, 11, 24),
              );
              done = true;
            },
            child: const Text('open'),
          ),
        ),
        glass: glass,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    if (glass) {
      expect(find.byType(CupertinoDatePicker), findsOneWidget);
      expect(find.byType(DatePickerDialog), findsNothing);
      await tester.tap(find.text('Done'));
    } else {
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(find.byType(CupertinoDatePicker), findsNothing);
      await tester.tap(find.text('OK'));
    }
    await tester.pumpAndSettle();
    expect(done, isTrue);
    return result;
  }

  testWidgets('日期选择：Apple 是 CupertinoDatePicker sheet，M3E 是 SDK 对话框', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    expect(await openDate(tester, glass: true), DateTime(2026, 3, 10));
    expect(await openDate(tester, glass: false), DateTime(2026, 3, 10));
  });

  testWidgets('时间选择：Apple 是 CupertinoDatePicker，M3E 是 TimePickerDialog', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final bool glass in <bool>[true, false]) {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showFushiTimePicker(
                context: context,
                initialTime: const TimeOfDay(hour: 9, minute: 30),
              ),
              child: const Text('open'),
            ),
          ),
          glass: glass,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.byType(CupertinoDatePicker),
        glass ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(TimePickerDialog),
        glass ? findsNothing : findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
  });
}
