import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustrations.dart';

/// 歌词模式插图的交互（2026-10-07）：横屏封面位换图 / 点掉回封面 / 左右切换 /
/// 点中间看大图；竖屏小封面入口；大图浏览翻页与关闭回封面。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

LyricsIllustration _item(String key, int chapter) => LyricsIllustration(
  key: key,
  position: LyricsBookPosition(chapter, 0),
  image: MemoryImage(_png),
);

LyricsIllustrationController _controller() =>
    LyricsIllustrationController()..load(
      <LyricsIllustration>[_item('a', 1), _item('b', 2), _item('c', 3)],
      position: const LyricsBookPosition(0, 0),
      audioPosition: Duration.zero,
    );

/// 顺着播走过前两张（a、b），封面位换成 a。
void _playPastTwo(LyricsIllustrationController c) => c.observe(
  const LyricsBookPosition(2, 10),
  audioPosition: const Duration(seconds: 5),
);

const Key _coverKey = ValueKey<String>('design_cover');
const Key _cardKey = ValueKey<String>('lyrics_illustration_card');

Widget _slotApp(LyricsIllustrationController c, {ValueChanged<int>? onOpen}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: LyricsIllustrationArtworkSlot(
            controller: c,
            side: 300,
            borderRadius: BorderRadius.circular(28),
            onOpen: onOpen,
            cover: const SizedBox.square(
              key: _coverKey,
              dimension: 300,
              child: ColoredBox(color: Colors.teal),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('横屏：播放走过插图时封面换成插图，✕ 回到封面', (WidgetTester tester) async {
    final LyricsIllustrationController c = _controller();
    await tester.pumpWidget(_slotApp(c));
    expect(find.byKey(_coverKey), findsOneWidget);
    expect(find.byKey(_cardKey), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('lyrics_artwork_badge')),
      findsNothing,
      reason: '一张都没听到时不出插图入口',
    );

    _playPastTwo(c);
    await tester.pumpAndSettle();
    expect(find.byKey(_cardKey), findsOneWidget);
    expect(find.byKey(_coverKey), findsNothing);
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_illustration_close')),
    );
    await tester.pumpAndSettle();
    expect(c.shown, isNull);
    expect(find.byKey(_coverKey), findsOneWidget);
    expect(find.byKey(_cardKey), findsNothing);

    // 回到封面后，封面角上的插图胶囊（或点封面）把最近一张插图找回来。
    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_artwork_badge')),
    );
    await tester.pumpAndSettle();
    expect(c.shown, 1);
    expect(find.text('2 / 2'), findsOneWidget);
  });

  testWidgets('横屏：点插图左 / 右三分之一切换，点中间看大图', (WidgetTester tester) async {
    final LyricsIllustrationController c = _controller();
    final List<int> opened = <int>[];
    await tester.pumpWidget(_slotApp(c, onOpen: opened.add));
    _playPastTwo(c);
    await tester.pumpAndSettle();
    expect(c.shown, 0);

    Rect card() => tester.getRect(find.byKey(_cardKey));
    await tester.tapAt(Offset(card().right - 12, card().bottom - 60));
    await tester.pumpAndSettle();
    expect(c.shown, 1);

    // 已到最后一张已听到的插图：右侧不再前进，点中间才是看大图。
    await tester.tapAt(Offset(card().right - 12, card().bottom - 60));
    await tester.pumpAndSettle();
    expect(c.shown, 1);
    expect(opened, <int>[1], reason: '没有下一张时右侧热区退化成看大图');

    await tester.tapAt(card().center);
    await tester.pumpAndSettle();
    expect(opened, <int>[1, 1]);

    await tester.tapAt(Offset(card().left + 12, card().bottom - 60));
    await tester.pumpAndSettle();
    expect(c.shown, 0);
  });

  testWidgets('竖屏：小封面在有插图时可点，带新插图提示点', (WidgetTester tester) async {
    final LyricsIllustrationController c = _controller();
    final List<int> opened = <int>[];
    final List<ImageProvider?> drawn = <ImageProvider?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LyricsIllustrationCompactArtwork(
              controller: c,
              onOpen: opened.add,
              builder: (BuildContext context, ImageProvider? illustration) {
                drawn.add(illustration);
                return const SizedBox.square(dimension: 44);
              },
            ),
          ),
        ),
      ),
    );
    const Key entry = ValueKey<String>('lyrics_compact_artwork');
    expect(find.byKey(entry), findsNothing, reason: '没听到插图时只是封面');
    expect(drawn.last, isNull);

    _playPastTwo(c);
    await tester.pumpAndSettle();
    expect(find.byKey(entry), findsOneWidget);
    expect(drawn.last, isNotNull, reason: '新插图到达：小方块换成插图');
    expect(
      find.byKey(const ValueKey<String>('lyrics_compact_artwork_dot')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(entry));
    expect(opened, <int>[0]);

    c.dismiss();
    await tester.pumpAndSettle();
    expect(drawn.last, isNull);
    expect(
      find.byKey(const ValueKey<String>('lyrics_compact_artwork_dot')),
      findsNothing,
    );
    await tester.tap(find.byKey(entry));
    expect(opened, <int>[0, 1], reason: '回封面后从最近听到的那张看起');
  });

  testWidgets('大图浏览：只翻已听到的插图，翻页同步封面位，关掉回封面', (WidgetTester tester) async {
    final LyricsIllustrationController c = _controller();
    _playPastTwo(c);
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            hostContext = context;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    final Future<void> done = showLyricsIllustrationViewer(
      hostContext,
      controller: c,
      index: 0,
      returnToCover: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_prev')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_next')),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(c.shown, 1);
    expect(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_next')),
      findsNothing,
      reason: '第三张还没听到，不给翻（不剧透）',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_close')),
    );
    await tester.pumpAndSettle();
    await done;
    expect(c.shown, isNull, reason: '竖屏入口看完就回封面');
  });
}
