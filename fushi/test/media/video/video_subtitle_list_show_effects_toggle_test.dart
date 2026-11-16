// 字幕列表「显示特效字幕」开关（拍板台 H7r4mf_z2n，维护者截图：一集里的插曲卡拉 OK
// 歌词混在台词列表里）。特效判据在 Rust 解析层（AudioCue.isEffect），列表只读这一位：
// 默认开（列出特效，与加开关前一致）；关掉后卡拉 OK 歌词、逐字 \pos 拼成的整句、屏幕字
// 都不再出现在列表里，普通台词不受影响；切换经 onShowEffectsChanged 交页面落盘，
// initialShowEffects 恢复上次的选择。两套版式（classic / m3e）各验一遍。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

const ValueKey<String> _toggleKey = ValueKey<String>(
  'video-subtitle-list-show-effects',
);

/// 一句普通台词、一句 \k 卡拉 OK 歌词、一句被逐字 \pos 拆开的歌词（列表会拼成整句）、
/// 一块屏幕字招牌、再一句普通台词。
const String _ass =
    '[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n\n'
    '[Events]\nFormat: Layer, Start, End, Style, Text\n'
    'Dialogue: 0,0:00:01.00,0:00:02.00,Default,{\\fad(100,100)}普通台词一\n'
    'Dialogue: 0,0:00:03.00,0:00:04.00,Default,{\\k30}そよぐ{\\k40}はずない風に\n'
    'Dialogue: 0,0:00:05.00,0:00:06.00,Default,{\\pos(900,1000)}吹\n'
    'Dialogue: 0,0:00:05.05,0:00:06.00,Default,{\\pos(960,1000)}か\n'
    'Dialogue: 0,0:00:05.10,0:00:06.00,Default,{\\pos(1020,1000)}れ\n'
    'Dialogue: 0,0:00:07.00,0:00:08.00,Default,{\\an8\\pos(960,80)}STARRY\n'
    'Dialogue: 0,0:00:09.00,0:00:10.00,Default,普通台词二\n';

Widget _panel({
  required VideoSubtitleListLayout layout,
  required VideoPlayerController controller,
  required bool initialShowEffects,
  required List<bool> persisted,
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
            onCopyCue: (_) => true,
            onFavoriteCue: (_) async {},
            isCueFavorited: (_) => false,
            onClose: () {},
            colorScheme: const ColorScheme.dark(),
            title: 'Subtitle list',
            emptyHint: 'empty',
            width: 520,
          ),
        ],
      ),
    ),
  );
}

Finder _row(String text) => find.text(text, findRichText: true);

void _expectEffectsListed(bool listed) {
  final Matcher m = listed ? findsOneWidget : findsNothing;
  expect(_row('そよぐはずない風に'), m, reason: '\\k 卡拉 OK 歌词');
  expect(_row('吹かれ'), m, reason: '逐字 \\pos 拼成的整句');
  expect(_row('STARRY'), m, reason: '\\pos 屏幕字');
  // 普通台词恒在。
  expect(_row('普通台词一'), findsOneWidget);
  expect(_row('普通台词二'), findsOneWidget);
}

void main() {
  test('parser flags the fixture as expected', () {
    final List<AudioCue> cues = AssParser.parseString(
      content: _ass,
      bookKey: 'video/1',
    );
    expect(
      cues.where((AudioCue c) => c.isEffect).map((AudioCue c) => c.text),
      <String>['そよぐはずない風に', '吹', 'か', 'れ', 'STARRY'],
    );
  });

  for (final VideoSubtitleListLayout layout in <VideoSubtitleListLayout>[
    VideoSubtitleListLayout.classic,
    VideoSubtitleListLayout.m3e,
  ]) {
    testWidgets('${layout.name}: effects listed by default; toggle hides them '
        'and persists, toggling back restores', (WidgetTester tester) async {
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
          initialShowEffects: true,
          persisted: persisted,
        ),
      );
      await tester.pump();
      _expectEffectsListed(true);

      expect(find.byKey(_toggleKey), findsOneWidget);
      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(persisted, <bool>[false]);
      _expectEffectsListed(false);

      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(persisted, <bool>[false, true]);
      _expectEffectsListed(true);
    });

    testWidgets('${layout.name}: initialShowEffects=false restores the hidden '
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
          initialShowEffects: false,
          persisted: <bool>[],
        ),
      );
      await tester.pump();
      _expectEffectsListed(false);
    });
  }
}
