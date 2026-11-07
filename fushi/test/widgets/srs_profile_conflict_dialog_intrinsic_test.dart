import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/pages/implementations/srs/srs_sync_settings.dart';
import 'package:fushi/src/utils/components/fushi_list_tile.dart';
import 'package:fushi/src/utils/components/fushi_marquee.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart' show SrsProfileConflict;
import 'package:marquee/marquee.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4237：SRS「复习同步冲突」弹窗在 debug 构建里不显示，只剩遮罩挡住复习页。
///
/// 根因：候选行 [FushiListTile] 的标题 / 副标题是 [FushiMarquee]，它靠
/// `LayoutBuilder` 判断放不放得下；对话框（MD3 的 AlertDialog、Apple 表单式面板）
/// 都把正文包在 `IntrinsicWidth` 里量宽，问到 `LayoutBuilder` 时 debug 抛
/// 「LayoutBuilder does not support returning intrinsic dimensions」、面板没有尺寸，
/// 随后命中测试再抛「Cannot hit test a render box with no size」——遮罩点不掉；
/// release 跳过断言答 0，弹窗显示得出来但候选行在量宽时被当成 0 宽。
void main() {
  ThemeData theme({required bool glass}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  );

  const SrsRemoteProfile candidate = SrsRemoteProfile(
    uid: 'b7c1d2e3f4a5',
    writers: <String>['dev-a#1'],
    names: <String>{'Main profile on the desktop computer upstairs'},
    devices: <String>['DESKTOP-ABCDEFG', 'Pixel 9 Pro XL'],
    noteCount: 1234,
    updatedAt: 1762500000000,
  );
  const SrsProfileConflict conflict = SrsProfileConflict(
    directoryKey: 'dir',
    localUid: 'local',
    candidates: <SrsRemoteProfile>[candidate],
    localHasNotes: true,
    localNoteCount: 56,
  );

  Future<Future<SrsProfileConflictChoice?>> open(
    WidgetTester tester, {
    required bool glass,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext opener;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(glass: glass),
        builder: (BuildContext context, Widget? child) =>
            FushiGlassScope(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              opener = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    final Future<SrsProfileConflictChoice?> result =
        showSrsProfileConflictDialog(opener, conflict);
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return result;
  }

  for (final bool glass in <bool>[false, true]) {
    final String design = glass ? 'Apple 玻璃' : 'MD3';
    testWidgets('$design：冲突弹窗量宽不抛 intrinsic 错，候选行有尺寸、点得中', (
      WidgetTester tester,
    ) async {
      final Future<SrsProfileConflictChoice?> result = await open(
        tester,
        glass: glass,
      );
      expect(tester.takeException(), isNull);
      final Finder tile = find.byKey(
        ValueKey<String>('srs-profile-conflict-${candidate.uid}'),
      );
      expect(tile, findsOneWidget);
      final Size size = tester.getSize(tile);
      expect(size.width, greaterThan(200));
      expect(size.height, greaterThan(40));
      // 点候选行（命中测试走得通才收得到选择）。
      await tester.tap(tile);
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      final SrsProfileConflictChoice? choice = await result;
      expect(choice, isA<SrsProfileConflictAdopt>());
      expect((choice! as SrsProfileConflictAdopt).uid, candidate.uid);
    });
  }

  group('FushiMarquee 在 intrinsic 量取下', () {
    Future<void> pumpBox(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: child)),
        ),
      );
      await tester.pump();
    }

    testWidgets('IntrinsicWidth 包住时按文字自然宽取宽、一行高', (WidgetTester tester) async {
      const TextStyle style = TextStyle(fontSize: 20);
      await pumpBox(
        tester,
        const DefaultTextStyle(
          style: style,
          child: IntrinsicWidth(
            child: FushiMarquee(key: ValueKey<String>('m'), text: 'Hello'),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final TextPainter tp = TextPainter(
        text: const TextSpan(text: 'Hello', style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final Size size = tester.getSize(find.byKey(const ValueKey<String>('m')));
      expect(size.width, moreOrLessEquals(tp.width, epsilon: 0.5));
      expect(size.height, moreOrLessEquals(tp.height, epsilon: 0.5));
      tp.dispose();
    });

    testWidgets('放不下时走滚动、高度等于实际字号的一行（量字用继承样式）', (WidgetTester tester) async {
      const TextStyle style = TextStyle(fontSize: 30);
      await pumpBox(
        tester,
        const SizedBox(
          width: 120,
          child: DefaultTextStyle(
            style: style,
            child: IntrinsicHeight(
              child: FushiMarquee(
                key: ValueKey<String>('m'),
                text: 'A long title that cannot fit in the box',
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final TextPainter tp = TextPainter(
        text: const TextSpan(text: 'A', style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final Size size = tester.getSize(find.byKey(const ValueKey<String>('m')));
      expect(find.byType(Marquee), findsOneWidget);
      expect(size.width, 120);
      expect(size.height, moreOrLessEquals(tp.height, epsilon: 0.5));
      tp.dispose();
      // 卸掉跑马灯，别留下滚动计时器。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('FushiListTile 放进 IntrinsicWidth 不抛错', (
      WidgetTester tester,
    ) async {
      await pumpBox(
        tester,
        const IntrinsicWidth(
          child: FushiListTile(
            key: ValueKey<String>('t'),
            title: 'Title',
            subtitle: 'Subtitle',
            icon: FushiIcons.cloudSync,
            selected: false,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('t'))).width,
        greaterThan(0),
      );
    });
  });
}
