import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustrations.dart';
import 'package:fushi/src/platform/host_platform.dart';
import 'package:fushi/src/reader/image_actions_sheet.dart';

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
    // 计数是全书插图数（反馈 wV1kvoLjI3），不是已听到的张数。
    expect(find.text('1 / 3'), findsOneWidget);

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
    expect(find.text('2 / 3'), findsOneWidget);
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
    // 反馈 wV1kvoLjI3：没听到插图时也能打开浏览（全部插图，未听到的遮着）；
    // 小方块本身仍画封面。
    expect(find.byKey(entry), findsOneWidget);
    expect(drawn.last, isNull);
    await tester.tap(find.byKey(entry));
    expect(opened, <int>[0]);
    opened.clear();

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

  // 反馈 VaaRL9s3Tg：小封面打开大图（不回封面的入口）看过后，缩略图仍留着插图，
  // 但「新插图」提示点必须消失；换上新插图时再出现。
  testWidgets('竖屏：打开大图看过后提示点消失，换上新插图再出现', (WidgetTester tester) async {
    final LyricsIllustrationController c = _controller()
      // 「红点」提示方式：不弹卡（不起自动收起计时），只换缩略图 + 提示点。
      ..autoOpenCard = false;
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              hostContext = context;
              return Center(
                child: LyricsIllustrationCompactArtwork(
                  controller: c,
                  onOpen: (int index) => showLyricsIllustrationViewer(
                    hostContext,
                    controller: c,
                    index: index,
                  ),
                  builder: (BuildContext context, ImageProvider? _) =>
                      const SizedBox.square(dimension: 44),
                ),
              );
            },
          ),
        ),
      ),
    );
    const Key dot = ValueKey<String>('lyrics_compact_artwork_dot');

    _playPastTwo(c);
    await tester.pumpAndSettle();
    expect(c.shown, 0);
    expect(find.byKey(dot), findsOneWidget, reason: '换上了没看过的插图');

    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_compact_artwork')),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_close')),
    );
    await tester.pumpAndSettle();
    expect(c.shown, 0, reason: '不回封面的入口：插图位仍是这张插图');
    expect(find.byKey(dot), findsNothing, reason: '看过大图：提示点消失');

    // 顺着播走过第三张：换上新插图，提示点重新出现。
    c.observe(
      const LyricsBookPosition(3, 10),
      audioPosition: const Duration(seconds: 10),
    );
    await tester.pumpAndSettle();
    expect(c.shown, 2);
    expect(find.byKey(dot), findsOneWidget, reason: '换上新插图：提示点再出现');
  });

  // 反馈 wV1kvoLjI3（维护者 2026-11-24）：大图浏览列出全书插图，还没听到的默认
  // 遮罩、点一下揭开；揭开写回宿主（与阅读器共用揭开状态）。
  testWidgets('大图浏览：列出全部插图，未听到的遮着、点一下揭开，翻页同步封面位', (WidgetTester tester) async {
    final List<String> revealedKeys = <String>[];
    final LyricsIllustrationController c = _controller()
      ..onReveal = revealedKeys.add;
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
    expect(find.text('1 / 3'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_prev')),
      findsNothing,
    );
    const Key next = ValueKey<String>('lyrics_illustration_viewer_next');
    const Key reveal = ValueKey<String>('lyrics_illustration_viewer_reveal');

    await tester.tap(find.byKey(next));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    expect(c.shown, 1);
    expect(find.byKey(reveal), findsNothing, reason: '听到过的不遮');

    // 第三张还没听到：照样能翻到，但盖着遮罩；插图位不换成它（缩略图不画遮罩）。
    await tester.tap(find.byKey(next));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.byKey(reveal), findsOneWidget);
    expect(find.text(t.lyrics_illustration_locked_hint), findsOneWidget);
    expect(c.shown, 1);
    expect(c.isLocked(2), isTrue);

    await tester.tap(find.byKey(reveal));
    await tester.pumpAndSettle();
    expect(find.byKey(reveal), findsNothing, reason: '点一下揭开');
    expect(c.isLocked(2), isFalse);
    expect(c.shown, 2, reason: '揭开后插图位同步到这张');
    expect(revealedKeys, <String>['c'], reason: '揭开写回宿主的揭开状态');

    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_close')),
    );
    await tester.pumpAndSettle();
    await done;
    expect(c.shown, isNull, reason: '竖屏入口看完就回封面');
  });

  // 反馈 wV1kvoLjI3「后面的图片有一张新出现，但是这里竟然没有」：浏览期间音频照常
  // 播放，旧实现建页时读一次已听到范围、之后不刷新，浏览中新走过的插图（插图位已
  // 换上它、缩略图已更新）在浏览里看不到。现在浏览监听状态机，新走过的那页当场解锁。
  testWidgets('大图浏览打开期间播放走过新插图：那一页当场解锁', (WidgetTester tester) async {
    final LyricsIllustrationController c = _controller()..autoOpenCard = false;
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
    unawaited(
      showLyricsIllustrationViewer(hostContext, controller: c, index: 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_next')),
    );
    await tester.pumpAndSettle();
    const Key reveal = ValueKey<String>('lyrics_illustration_viewer_reveal');
    expect(find.byKey(reveal), findsOneWidget);

    c.observe(
      const LyricsBookPosition(3, 10),
      audioPosition: const Duration(seconds: 10),
    );
    await tester.pumpAndSettle();
    expect(c.reached, 2);
    expect(find.byKey(reveal), findsNothing, reason: '新走过的插图不再遮着');
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('大图浏览：遮着的页按 Enter 揭开（键盘 / 手柄可达）', (WidgetTester tester) async {
    final LyricsIllustrationController c = _controller();
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
    // 一张都没听到也能打开：从第一张（遮着）看起。
    expect(c.browseStart, 0);
    unawaited(
      showLyricsIllustrationViewer(hostContext, controller: c, index: 0),
    );
    await tester.pumpAndSettle();
    const Key reveal = ValueKey<String>('lyrics_illustration_viewer_reveal');
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.byKey(reveal), findsOneWidget);
    expect(c.shown, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(reveal), findsNothing);
    expect(c.shown, 0);
  });

  testWidgets('长按插图卡 / 大图：弹全局图片动作面板（有磁盘文件才挂）', (WidgetTester tester) async {
    final LyricsIllustrationController c = LyricsIllustrationController()
      ..load(
        <LyricsIllustration>[
          LyricsIllustration(
            key: 'a',
            position: const LyricsBookPosition(1, 0),
            image: MemoryImage(_png),
            file: File('/books/OEBPS/a.png'),
          ),
        ],
        position: const LyricsBookPosition(0, 0),
        audioPosition: Duration.zero,
      );
    c.observe(
      const LyricsBookPosition(2, 10),
      audioPosition: const Duration(seconds: 5),
    );
    await tester.pumpWidget(_slotApp(c));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(_cardKey));
    await tester.pumpAndSettle();
    expect(find.byType(ImageActionsSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('image_action_save')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ImageActionsSheet), findsNothing);

    // 测试里的内存图源（file == null）不挂长按。
    final LyricsIllustrationController noFile = _controller();
    _playPastTwo(noFile);
    await tester.pumpWidget(_slotApp(noFile));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(_cardKey));
    await tester.pumpAndSettle();
    expect(find.byType(ImageActionsSheet), findsNothing);
    // 两张卡都没进停留：到展示时长自动收起（BUG-4065），计时不留到测试结束。
    await tester.pump(lyricsIllustrationCardDisplayDuration(0));
    expect(c.cardVisible, isFalse);
    expect(noFile.cardVisible, isFalse);
  });
  // BUG-5407（反馈 oYQN9hgT9G）：插图卡 / 大图只挂了长按，Windows 右键被吞、
  // 没有任何反应。现在与阅读器正文看图同一个「保存图片 / 复制图片」右键菜单。
  testWidgets('Windows 右键插图卡 / 大图：弹保存 / 复制图片菜单', (WidgetTester tester) async {
    debugHostPlatformOverride = HostPlatform.windows;
    addTearDown(() => debugHostPlatformOverride = null);
    final LyricsIllustrationController c = LyricsIllustrationController()
      ..load(
        <LyricsIllustration>[
          LyricsIllustration(
            key: 'a',
            position: const LyricsBookPosition(1, 0),
            image: MemoryImage(_png),
            file: File('/books/OEBPS/a.png'),
          ),
        ],
        position: const LyricsBookPosition(0, 0),
        audioPosition: Duration.zero,
      );
    c.observe(
      const LyricsBookPosition(2, 10),
      audioPosition: const Duration(seconds: 5),
    );
    final Finder save = find.text(t.reader_image_save);
    final Finder copy = find.text(t.reader_copy_image);
    Future<void> rightClick(Finder target) async {
      final TestGesture mouse = await tester.startGesture(
        tester.getCenter(target),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();
    }

    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              hostContext = context;
              return Center(
                child: LyricsIllustrationArtworkSlot(
                  controller: c,
                  side: 300,
                  borderRadius: BorderRadius.circular(28),
                  cover: const SizedBox.square(key: _coverKey, dimension: 300),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 插图卡：右键出菜单（不是长按面板）。
    await rightClick(find.byKey(_cardKey));
    expect(save, findsOneWidget);
    expect(copy, findsOneWidget);
    expect(find.byType(ImageActionsSheet), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(copy, findsNothing);

    // 大图浏览：已解锁的那页右键同样出菜单。
    unawaited(
      showLyricsIllustrationViewer(hostContext, controller: c, index: 0),
    );
    await tester.pumpAndSettle();
    await rightClick(
      find.byKey(const ValueKey<String>('lyrics_illustration_viewer_pages')),
    );
    expect(save, findsOneWidget);
    expect(copy, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(copy, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 非 Windows：不挂右键菜单（复制走 Windows 原生剪贴板通道），长按照旧。
    debugHostPlatformOverride = HostPlatform.android;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LyricsIllustrationArtworkSlot(
              controller: c,
              side: 300,
              borderRadius: BorderRadius.circular(28),
              cover: const SizedBox.square(key: _coverKey, dimension: 300),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await rightClick(find.byKey(_cardKey));
    expect(copy, findsNothing);
    c.dismiss();
    await tester.pump(lyricsIllustrationCardDisplayDuration(0));
  });

  testWidgets('插图卡没进停留时按「图片暂停」秒数自动收起', (WidgetTester tester) async {
    final ValueNotifier<int> pause = ValueNotifier<int>(9);
    addTearDown(pause.dispose);
    final LyricsIllustrationController c = _controller()..imagePauseSec = pause;
    _playPastTwo(c);
    await tester.pumpWidget(_slotApp(c));
    await tester.pumpAndSettle();
    expect(find.byKey(_cardKey), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    expect(c.cardVisible, isTrue, reason: '9 秒停留设置下 8 秒时卡还在（旧实现固定 5 秒就收）');
    expect(find.byKey(_cardKey), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(c.cardVisible, isFalse);
    expect(c.shown, 0, reason: '只收卡，插图位仍是这张插图');
  });
}
