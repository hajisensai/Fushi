// 字幕列表「显示特效字幕」开关（拍板台 H7r4mf_z2n，维护者截图：一集里的插曲卡拉 OK
// 歌词混在台词列表里）。特效判据在 Rust 解析层（AudioCue.isEffect），列表只读这一位：
// 默认关（拍板选项 B「默认隐藏特效事件」）——卡拉 OK 歌词、逐字拆开的歌词、屏幕字都不
// 出现在列表里，普通台词（含只带 \pos 定位的对白）不受影响；切换经 onShowEffectsChanged
// 交页面落盘，initialShowEffects 恢复上次的选择。收藏计数与列表走同一基集合（BUG-841）。
// 两套版式（classic / m3e）各验一遍。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

const ValueKey<String> _toggleKey = ValueKey<String>(
  'video-subtitle-list-show-effects',
);

/// 一句普通台词、一句 \k 卡拉 OK 歌词、一句被逐字 \pos 拆开的歌词（同一行单字同时在屏，
/// 解析层按组判成特效；列表会拼成整句）、
/// 一块旋转的屏幕字招牌、一句只带 \pos 定位的对白（不少字幕组每行都这样写，不算特效）、
/// 一组「特效阴影层在前 + 普通拷贝在后」的同句（去重后代表行是特效层，但整句是台词）、
/// 再一句普通台词。
const String _ass =
    '[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n\n'
    '[Events]\nFormat: Layer, Start, End, Style, Text\n'
    'Dialogue: 0,0:00:01.00,0:00:02.00,Default,{\\fad(100,100)}普通台词一\n'
    'Dialogue: 0,0:00:03.00,0:00:04.00,Default,{\\k30}そよぐ{\\k40}はずない風に\n'
    'Dialogue: 0,0:00:05.00,0:00:06.00,Default,{\\pos(900,1000)\\fad(100,100)}吹\n'
    'Dialogue: 0,0:00:05.05,0:00:06.00,Default,{\\pos(960,1000)\\fad(100,100)}か\n'
    'Dialogue: 0,0:00:05.10,0:00:06.00,Default,{\\pos(1020,1000)\\fad(100,100)}れ\n'
    'Dialogue: 0,0:00:07.00,0:00:08.00,Default,{\\an8\\pos(960,80)\\frz8}STARRY\n'
    'Dialogue: 0,0:00:09.00,0:00:10.00,Default,{\\pos(580,900)}定位台词\n'
    'Dialogue: 1,0:00:11.00,0:00:12.00,Default,{\\t(0,200,\\blur4)}阴影台词\n'
    'Dialogue: 0,0:00:11.00,0:00:12.00,Default,阴影台词\n'
    'Dialogue: 0,0:00:13.00,0:00:14.00,Default,普通台词二\n';

const String _effectLyric = 'そよぐはずない風に';

Widget _panel({
  required VideoSubtitleListLayout layout,
  required VideoPlayerController controller,
  required bool initialShowEffects,
  required List<bool> persisted,
  VideoSubtitleListFilter initialFilter = VideoSubtitleListFilter.all,
  bool Function(AudioCue cue)? isCueFavorited,
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

void _expectEffectsListed(bool listed) {
  final Matcher m = listed ? findsOneWidget : findsNothing;
  expect(_row(_effectLyric), m, reason: '\\k 卡拉 OK 歌词');
  expect(_row('吹かれ'), m, reason: '逐字 \\pos 拼成的整句');
  expect(_row('STARRY'), m, reason: '旋转屏幕字');
  // 普通台词恒在：只带 \pos 的对白、代表行是特效层但同组有普通拷贝的台词也是台词。
  expect(_row('普通台词一'), findsOneWidget);
  expect(_row('定位台词'), findsOneWidget);
  expect(_row('阴影台词'), findsOneWidget);
  expect(_row('普通台词二'), findsOneWidget);
}

void main() {
  test('parser flags the fixture as expected', () {
    final List<AudioCue> cues = AssParser.parseString(
      content: _ass,
      bookKey: 'video/1',
    );
    expect(
      <String>[
        for (final AudioCue c in cues)
          if (c.isEffect) c.text,
      ],
      <String>[_effectLyric, '吹', 'か', 'れ', 'STARRY', '阴影台词'],
    );
  });

  test('panel hides effects unless told otherwise (decision option B)', () {
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

  for (final VideoSubtitleListLayout layout in <VideoSubtitleListLayout>[
    VideoSubtitleListLayout.classic,
    VideoSubtitleListLayout.m3e,
  ]) {
    testWidgets('${layout.name}: effects hidden; toggle lists them and '
        'persists, toggling back hides again', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(
        AssParser.parseString(content: _ass, bookKey: 'video/1'),
      );
      final List<bool> persisted = <bool>[];

      await tester.pumpWidget(
        _panel(
          layout: layout,
          controller: controller,
          initialShowEffects: false,
          persisted: persisted,
        ),
      );
      await tester.pump();
      _expectEffectsListed(false);

      expect(find.byKey(_toggleKey), findsOneWidget);
      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(persisted, <bool>[true]);
      _expectEffectsListed(true);

      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(persisted, <bool>[true, false]);
      _expectEffectsListed(false);
    });

    testWidgets('${layout.name}: initialShowEffects=true restores the listed '
        'state on open', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(
        AssParser.parseString(content: _ass, bookKey: 'video/1'),
      );
      await tester.pumpWidget(
        _panel(
          layout: layout,
          controller: controller,
          initialShowEffects: true,
          persisted: <bool>[],
        ),
      );
      await tester.pump();
      _expectEffectsListed(true);
    });

    // BUG-841 约束：收藏计数与收藏档列表走同一基集合。特效被隐藏时，只收藏了一句特效
    // 歌词 → 列表空、计数也是 0（修复前计数仍数到被隐藏的那句，显示「收藏 1 句」）。
    testWidgets('${layout.name}: hidden effect favorites are not counted', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(
        AssParser.parseString(content: _ass, bookKey: 'video/1'),
      );
      final List<bool> persisted = <bool>[];
      await tester.pumpWidget(
        _panel(
          layout: layout,
          controller: controller,
          initialShowEffects: false,
          persisted: persisted,
          initialFilter: VideoSubtitleListFilter.favorites,
          isCueFavorited: (AudioCue c) => c.text == _effectLyric,
        ),
      );
      await tester.pump();
      expect(_row(_effectLyric), findsNothing);
      expect(
        find.text(t.video_subtitle_filter_favorites_empty),
        findsOneWidget,
      );
      expect(find.text(t.video_favorite_count(count: 0)), findsOneWidget);
      expect(find.text(t.video_favorite_count(count: 1)), findsNothing);

      // 打开开关后那句收藏回到列表，计数同步变 1。开关必须不经滚动就能直接命中。
      expect(find.byKey(_toggleKey).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(_row(_effectLyric), findsOneWidget);
      expect(find.text(t.video_favorite_count(count: 1)), findsOneWidget);
    });
  }

  // 经典版式收藏档：右侧多出导出钮与「收藏 N」计数。开关曾排在可横向拖动的筛选区里，
  // 窄面板下被挤出视口、要横向拖才看得到。520 与最窄 240 面板都必须不经滚动直接命中，
  // 且整颗按钮落在面板内。
  for (final double width in <double>[520, 240]) {
    testWidgets('classic favorites @${width.toInt()}: show-effects toggle is '
        'directly visible without scrolling', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(
        AssParser.parseString(content: _ass, bookKey: 'video/1'),
      );
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
