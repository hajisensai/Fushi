// 字幕列表「显示特效字幕」开关（拍板台 H7r4mf_z2n → left3545）。维护者 left3545 留言：
// 「我说的显示特效字幕是在字幕列表里面显示特效字幕的样式，不是用来筛选」。所以开关两态
// 列出的行完全相同；开着时特效行（解析层 AudioCue.isEffect：卡拉 OK、逐字 \pos 拆开的
// 歌词、旋转屏幕字……）按字幕自带样式着色（样式表主色 / 描边色、行内 \c），普通台词
// （含只带 \pos 定位的对白）照旧主题色。切换经 onShowEffectsChanged 交页面落盘，
// initialShowEffects 恢复上次选择。收藏计数与列表走同一基集合（BUG-841），不受开关影响。
// 两套版式（classic / m3e）、有无查词能力各验一遍。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

const ValueKey<String> _toggleKey = ValueKey<String>(
  'video-subtitle-list-show-effects',
);

/// 特效样式 OP 是红字（`&H000000FF` = BGR 红）+ 白描边；Default 是白字黑描边。
const Color _opRed = Color(0xFFFF0000);

/// 一句普通台词、一句 \k 卡拉 OK 歌词、一句被逐字 \pos 拆开的歌词（同一行单字同时在屏，
/// 解析层按组判成特效；列表会拼成整句）、一块旋转的屏幕字招牌、一句只带 \pos 定位的对白
/// （不少字幕组每行都这样写，不算特效）、一组「特效阴影层在前 + 普通拷贝在后」的同句、
/// 再一句普通台词。特效行都用 OP 样式。
const String _ass =
    '[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n\n'
    '[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, '
    'OutlineColour, Bold\n'
    'Style: Default,Arial,60,&H00FFFFFF,&H00000000,0\n'
    'Style: OP,Arial,60,&H000000FF,&H00FFFFFF,0\n\n'
    '[Events]\nFormat: Layer, Start, End, Style, Text\n'
    'Dialogue: 0,0:00:01.00,0:00:02.00,Default,{\\fad(100,100)}普通台词一\n'
    'Dialogue: 0,0:00:03.00,0:00:04.00,OP,{\\k30}そよぐ{\\k40}はずない風に\n'
    'Dialogue: 0,0:00:05.00,0:00:06.00,OP,{\\pos(900,1000)\\fad(100,100)}吹\n'
    'Dialogue: 0,0:00:05.05,0:00:06.00,OP,{\\pos(960,1000)\\fad(100,100)}か\n'
    'Dialogue: 0,0:00:05.10,0:00:06.00,OP,{\\pos(1020,1000)\\fad(100,100)}れ\n'
    'Dialogue: 0,0:00:07.00,0:00:08.00,OP,{\\an8\\pos(960,80)\\frz8}STARRY\n'
    'Dialogue: 0,0:00:09.00,0:00:10.00,OP,{\\pos(580,900)}定位台词\n'
    'Dialogue: 1,0:00:11.00,0:00:12.00,Default,{\\t(0,200,\\blur4)}阴影台词\n'
    'Dialogue: 0,0:00:11.00,0:00:12.00,Default,阴影台词\n'
    'Dialogue: 0,0:00:13.00,0:00:14.00,Default,普通台词二\n';

const String _effectLyric = 'そよぐはずない風に';

const List<String> _effectRows = <String>[_effectLyric, '吹かれ', 'STARRY'];

/// 普通台词：开关怎么切都在列表里、都不着色。「定位台词」虽然用了 OP 样式，但只带
/// \pos 不算特效（判据在解析层），所以也不着色。
const List<String> _plainRows = <String>['普通台词一', '定位台词', '普通台词二'];

Widget _panel({
  required VideoSubtitleListLayout layout,
  required VideoPlayerController controller,
  required bool initialShowEffects,
  required List<bool> persisted,
  VideoSubtitleListFilter initialFilter = VideoSubtitleListFilter.all,
  bool Function(AudioCue cue)? isCueFavorited,
  void Function(AudioCue cue, int grapheme, Rect anchor)? onLookupCue,
  double width = 520,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: <Widget>[
          VideoSubtitleJumpPanel(
            layout: layout,
            controller: controller,
            onTapCue: (_) {},
            onLookupCue: onLookupCue,
            initialShowEffects: initialShowEffects,
            onShowEffectsChanged: persisted.add,
            initialFilter: initialFilter,
            onCopyCue: (_) => true,
            onFavoriteCue: (_) async {},
            isCueFavorited: isCueFavorited ?? (_) => false,
            onExportFavorites: (_) async {},
            onClose: () {},
            colorScheme: const ColorScheme.dark(),
            title: 'Subtitle list',
            emptyHint: 'empty',
            width: width,
          ),
        ],
      ),
    ),
  );
}

Finder _row(String text) => find.text(text, findRichText: true);

/// 本行正文里是否有一段按 OP 样式的红字着色。
bool _rowIsStyled(WidgetTester tester, String text) {
  final RichText rich = tester.widget<RichText>(
    find.byWidgetPredicate(
      (Widget w) =>
          w is RichText &&
          w.text.toPlainText(includeSemanticsLabels: false) == text,
    ),
  );
  // 不用 visitChildren：它跳过没有 text 的容器 span，而样式正挂在容器上。
  bool walk(InlineSpan span) {
    if (span.style?.color == _opRed) return true;
    return span is TextSpan && (span.children?.any(walk) ?? false);
  }

  return walk(rich.text);
}

void _expectAllRowsListed() {
  for (final String text in <String>[..._effectRows, ..._plainRows]) {
    expect(_row(text), findsOneWidget, reason: text);
  }
  expect(_row('阴影台词'), findsOneWidget);
}

void _expectEffectStyles(WidgetTester tester, {required bool shown}) {
  _expectAllRowsListed();
  for (final String text in _effectRows) {
    expect(_rowIsStyled(tester, text), shown, reason: '特效行 $text');
  }
  for (final String text in _plainRows) {
    expect(_rowIsStyled(tester, text), isFalse, reason: '普通台词 $text');
  }
}

List<AudioCue> _cues() => AssParser.parseString(content: _ass, bookKey: 'v/1');

void main() {
  test('parser flags the fixture as expected', () {
    expect(
      <String>[
        for (final AudioCue c in _cues())
          if (c.isEffect) c.text,
      ],
      <String>[_effectLyric, '吹', 'か', 'れ', 'STARRY', '阴影台词'],
    );
  });

  test('panel shows effect lines in theme colour unless told otherwise', () {
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    final VideoSubtitleJumpPanel panel = VideoSubtitleJumpPanel(
      controller: controller,
      onTapCue: (_) {},
      onCopyCue: (_) => true,
      onFavoriteCue: (_) async {},
      isCueFavorited: (_) => false,
      onClose: () {},
      colorScheme: const ColorScheme.dark(),
      title: 'Subtitle list',
      emptyHint: 'empty',
    );
    expect(panel.initialShowEffects, isFalse);
  });

  group('subtitleListEffectSpan', () {
    final List<AudioCue> cues = _cues();
    AudioCue byText(String text) =>
        cues.firstWhere((AudioCue c) => c.text == text);

    test('plain dialogue is not styled', () {
      final AudioCue cue = byText('定位台词');
      expect(subtitleListEffectSpan(rowText: cue.text, cue: cue), isNull);
    });

    test('effect line carries its style and flattens to the row text', () {
      final AudioCue cue = byText(_effectLyric);
      final InlineSpan? span = subtitleListEffectSpan(
        rowText: cue.text,
        cue: cue,
      );
      expect(span, isNotNull);
      expect(span!.toPlainText(), _effectLyric);
      expect(span.style?.color, _opRed);
    });

    test('row text that no longer matches the markup falls back to plain', () {
      final AudioCue cue = byText(_effectLyric);
      expect(subtitleListEffectSpan(rowText: '手改过的文本', cue: cue), isNull);
    });

    test('per-character group is styled member by member', () {
      final rows = subtitleTranscriptRows(cues);
      final int rep = rows.mergedByRep.entries
          .firstWhere((MapEntry<int, AudioCue> e) => e.value.text == '吹かれ')
          .key;
      final InlineSpan? span = subtitleListEffectSpan(
        rowText: '吹かれ',
        cue: cues[rep],
        members: rows.mergedMembersByRep[rep],
      );
      expect(span, isNotNull);
      expect(span!.toPlainText(), '吹かれ');
    });
  });

  for (final VideoSubtitleListLayout layout in <VideoSubtitleListLayout>[
    VideoSubtitleListLayout.classic,
    VideoSubtitleListLayout.m3e,
  ]) {
    for (final bool lookup in <bool>[false, true]) {
      final String suffix = lookup ? ' (tap lookup)' : '';
      testWidgets('${layout.name}$suffix: toggle styles effect rows, never '
          'filters, and persists', (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final VideoPlayerController controller = VideoPlayerController();
        addTearDown(controller.dispose);
        controller.setCues(_cues());
        final List<bool> persisted = <bool>[];

        await tester.pumpWidget(
          _panel(
            layout: layout,
            controller: controller,
            initialShowEffects: false,
            persisted: persisted,
            onLookupCue: lookup ? (AudioCue c, int g, Rect r) {} : null,
          ),
        );
        await tester.pump();
        _expectEffectStyles(tester, shown: false);

        expect(find.byKey(_toggleKey), findsOneWidget);
        await tester.tap(find.byKey(_toggleKey));
        await tester.pump();
        expect(persisted, <bool>[true]);
        _expectEffectStyles(tester, shown: true);

        await tester.tap(find.byKey(_toggleKey));
        await tester.pump();
        expect(persisted, <bool>[true, false]);
        _expectEffectStyles(tester, shown: false);
      });
    }

    testWidgets('${layout.name}: initialShowEffects=true restores the styled '
        'state on open', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(_cues());
      await tester.pumpWidget(
        _panel(
          layout: layout,
          controller: controller,
          initialShowEffects: true,
          persisted: <bool>[],
        ),
      );
      await tester.pump();
      _expectEffectStyles(tester, shown: true);
    });

    // BUG-841 约束：收藏计数与收藏档列表走同一基集合。开关不筛选，所以收藏了一句特效
    // 歌词时，两态下它都在收藏档里、计数都是 1。
    testWidgets('${layout.name}: effect favorites stay listed and counted', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(_cues());
      await tester.pumpWidget(
        _panel(
          layout: layout,
          controller: controller,
          initialShowEffects: false,
          persisted: <bool>[],
          initialFilter: VideoSubtitleListFilter.favorites,
          isCueFavorited: (AudioCue c) => c.text == _effectLyric,
        ),
      );
      await tester.pump();
      expect(_row(_effectLyric), findsOneWidget);
      expect(find.text(t.video_favorite_count(count: 1)), findsOneWidget);

      expect(find.byKey(_toggleKey).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(_row(_effectLyric), findsOneWidget);
      expect(_rowIsStyled(tester, _effectLyric), isTrue);
      expect(find.text(t.video_favorite_count(count: 1)), findsOneWidget);
    });
  }

  // 经典版式收藏档：右侧多出导出钮与「收藏 N」计数。开关曾排在可横向拖动的筛选区里，
  // 窄面板下被挤出视口、要横向拖才看得到（BUG-4781）。520 与最窄 240 面板都必须不经
  // 滚动直接命中，且整颗按钮落在面板内。
  for (final double width in <double>[520, 240]) {
    testWidgets('classic favorites @${width.toInt()}: show-effects toggle is '
        'directly visible without scrolling', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(_cues());
      final List<bool> persisted = <bool>[];
      await tester.pumpWidget(
        _panel(
          layout: VideoSubtitleListLayout.classic,
          controller: controller,
          initialShowEffects: false,
          persisted: persisted,
          initialFilter: VideoSubtitleListFilter.favorites,
          isCueFavorited: (AudioCue c) => c.text == '普通台词一',
          width: width,
        ),
      );
      await tester.pump();

      final Finder toggle = find.byKey(_toggleKey);
      expect(toggle.hitTestable(), findsOneWidget);
      final Rect panelRect = tester.getRect(
        find.byType(VideoSubtitleJumpPanel),
      );
      final Rect toggleRect = tester.getRect(toggle);
      expect(
        toggleRect.left >= panelRect.left &&
            toggleRect.right <= panelRect.right,
        isTrue,
        reason: 'toggle $toggleRect must sit inside panel $panelRect',
      );
      await tester.tap(toggle);
      await tester.pump();
      expect(persisted, <bool>[true]);
    });
  }
}
