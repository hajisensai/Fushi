// 「在线搜索字幕」弹层的高度适配：
//
// - 横屏手机 + 软键盘（弹层正文只剩 ~110dp）：不溢出，搜索行完整在键盘上方，
//   搜索行并进结果的滚动视口一起滚。
// - 高度够时：搜索行固定在结果上方，滚结果不会把搜索行滚走；结果是懒构建的。
// - 键盘弹起触发两种排法切换时，搜索行原样搬家，输入焦点不丢。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_subtitle_search_sheet.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

const ValueKey<String> _queryKey = ValueKey<String>(
  'video-remote-subtitle-search-query',
);
const ValueKey<String> _headerKey = ValueKey<String>(
  'video-remote-subtitle-search-header',
);
const ValueKey<String> _scrollKey = ValueKey<String>(
  'video-remote-subtitle-search-scroll',
);

List<VideoRemoteSubtitleCandidate> _candidates(int count) =>
    <VideoRemoteSubtitleCandidate>[
      for (int i = 0; i < count; i++)
        VideoRemoteSubtitleCandidate(
          id: '$i',
          fileName: 'frieren_${i.toString().padLeft(2, '0')}.ja.srt',
          provider: 'jimaku',
          language: 'ja',
        ),
    ];

void _setView(WidgetTester tester, Size logical, {double keyboard = 0}) {
  const double dpr = 2.75;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
}

/// [focusRoot] = 外包 [FushiFocusRoot]（真 app 的焦点根）。竖屏底部弹层挂上它时，
/// 实测主焦点落在集号输入框的「粘贴」尾钮上，打开过程中报「Invisible
/// SemanticsNodes」断言；这在 develop（本弹层改排版之前的 Column 版）上同样复现，
/// 是与本弹层排版无关的独立问题，另案处理。本用例只验排版，不挂焦点根。
Future<void> _openSheet(
  WidgetTester tester,
  int resultCount, {
  bool focusRoot = true,
}) async {
  final ThemeData base = buildFushiThemeData(
    scheme: buildFushiColorScheme(
      seedColor: kFushiDefaultSeed,
      brightness: Brightness.light,
    ),
    designSystem: FushiDesignSystem.auto,
    glassDesign: false,
    textTheme: FushiTypeScale.buildTextTheme(const TextStyle()),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(platform: TargetPlatform.android),
      builder: (BuildContext context, Widget? app) =>
          focusRoot ? FushiFocusRoot(child: app!) : app!,
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showVideoRemoteSubtitleSearchSheet(
                context: context,
                search: (String? q, int? e) async =>
                    VideoRemoteSubtitleSearchResult(
                      query: 'Frieren',
                      episode: 3,
                      candidates: _candidates(resultCount),
                    ),
                download: (_) async {},
                errorText: (Object e) => '$e',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

bool _headerInsideScroll() => find
    .descendant(of: find.byKey(_scrollKey), matching: find.byKey(_headerKey))
    .evaluate()
    .isNotEmpty;

void main() {
  testWidgets(
    'landscape phone + keyboard: no overflow, search row above keyboard',
    (WidgetTester tester) async {
      const Size logical = Size(800, 360);
      const double keyboard = 200;
      _setView(tester, logical, keyboard: keyboard);
      addTearDown(tester.view.reset);

      await _openSheet(tester, 2);

      expect(tester.takeException(), isNull, reason: 'no layout overflow');
      expect(
        _headerInsideScroll(),
        isTrue,
        reason: 'too short to pin: search row scrolls with the results',
      );
      for (final String key in <String>[
        'video-remote-subtitle-search-query',
        'video-remote-subtitle-search-episode',
        'video-remote-subtitle-search-go',
      ]) {
        final Rect r = tester.getRect(find.byKey(ValueKey<String>(key)));
        expect(
          r.bottom,
          lessThanOrEqualTo(logical.height - keyboard + 0.5),
          reason: '$key must sit above the keyboard',
        );
      }
    },
  );

  testWidgets(
    'tall viewport: search row stays pinned while many results scroll, '
    'results are built lazily',
    (WidgetTester tester) async {
      const Size logical = Size(400, 900);
      _setView(tester, logical);
      addTearDown(tester.view.reset);

      const int count = 60;
      await _openSheet(tester, count, focusRoot: false);
      expect(tester.takeException(), isNull);
      expect(_headerInsideScroll(), isFalse, reason: 'header pinned above');

      // 懒构建：60 行远超视口，末尾的行不应被建出来。
      expect(
        find.byKey(
          const ValueKey<String>('video-remote-subtitle-${count - 1}'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      final RegExp tileKey = RegExp(r'^video-remote-subtitle-\d+$');
      final int built = find
          .byWidgetPredicate(
            (Widget w) =>
                w.key is ValueKey<String> &&
                tileKey.hasMatch((w.key! as ValueKey<String>).value),
            skipOffstage: false,
          )
          .evaluate()
          .length;
      expect(built, greaterThan(0));
      expect(built, lessThan(count));

      final Rect queryBefore = tester.getRect(find.byKey(_queryKey));
      final Rect firstBefore = tester.getRect(
        find.byKey(const ValueKey<String>('video-remote-subtitle-0')),
      );
      await tester.drag(find.byKey(_scrollKey), const Offset(0, -400));
      await tester.pumpAndSettle();

      // 结果确实滚了：第一行上移 / 已移出。
      final Finder first = find.byKey(
        const ValueKey<String>('video-remote-subtitle-0'),
      );
      if (first.evaluate().isNotEmpty) {
        expect(tester.getRect(first).top, lessThan(firstBefore.top - 100));
      }
      // 搜索行原地不动、仍完整在屏幕内。
      final Rect queryAfter = tester.getRect(find.byKey(_queryKey));
      expect(queryAfter, queryBefore);
      expect(queryAfter.top, greaterThanOrEqualTo(0));
      expect(queryAfter.bottom, lessThanOrEqualTo(logical.height));
      expect(find.byKey(_queryKey).hitTestable(), findsOneWidget);
    },
  );

  testWidgets('keyboard opening moves the search row without losing focus', (
    WidgetTester tester,
  ) async {
    const Size logical = Size(800, 700);
    _setView(tester, logical);
    addTearDown(tester.view.reset);

    await _openSheet(tester, 20);
    expect(_headerInsideScroll(), isFalse);

    await tester.showKeyboard(find.byKey(_queryKey));
    await tester.pump();
    final EditableTextState before = tester.state<EditableTextState>(
      find.descendant(
        of: find.byKey(_queryKey),
        matching: find.byType(EditableText),
      ),
    );
    expect(before.widget.focusNode.hasFocus, isTrue);

    // 键盘升起：弹层正文变矮，搜索行改为并进滚动视口。
    _setView(tester, logical, keyboard: 450);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_headerInsideScroll(), isTrue);

    final EditableTextState after = tester.state<EditableTextState>(
      find.descendant(
        of: find.byKey(_queryKey),
        matching: find.byType(EditableText),
      ),
    );
    expect(identical(after, before), isTrue, reason: 'same field state');
    expect(after.widget.focusNode.hasFocus, isTrue, reason: 'focus kept');
    expect(after.widget.controller.text, 'Frieren');
  });
}
