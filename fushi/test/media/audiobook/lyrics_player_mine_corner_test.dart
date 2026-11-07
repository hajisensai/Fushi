import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_card.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 歌词模式登记制卡角落锚点（群反馈 2026-11-01「字卡提示好大，还挡正文」）：
///  * 小卡贴的是歌词 WebView 的真实矩形——有跳转胶囊时 WebView 已从底边让出一条
///    带子，小卡底边不得落进带子、压在胶囊上；
///  * 歌词页被不透明路由盖住时不再贴到看不见的角上，退回默认大卡；
///  * 歌词页销毁后撤销登记。
class _FakeClock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 42);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

LyricsPlayerCallbacks _callbacks() => LyricsPlayerCallbacks(
  onClose: () {},
  onPlayPause: () {},
  onPreviousCue: () {},
  onNextCue: () {},
  onSeek: (_) {},
  onToggleMask: () {},
  onOpenStatistics: () {},
  onSpeedChanged: (_) {},
  onMore: (_) {},
  onTapBackground: () {},
);

Future<void> _showAdded(WidgetTester tester) async {
  FushiToast.showMine(msg: '已添加', status: MineToastStatus.added);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  // 手机竖屏与平板横屏（反馈 OOZ-lrCsU0：平板歌词模式小卡压住竖排正文）。
  for (final Size screen in const <Size>[Size(390, 844), Size(1280, 800)]) {
    testWidgets('歌词模式 $screen：制卡小卡放在歌词 WebView 外、不压歌词；被盖住 / 销毁后复原', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.view.physicalSize = screen;
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      FushiToast.navigatorKey = navKey;
      const Key lyricsKey = ValueKey<String>('lyrics_probe');
      Widget app({required bool lyrics}) => MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: lyrics
              ? ReaderLyricsPlayerOverlay(
                  lyricsView: const SizedBox.expand(key: lyricsKey),
                  data: LyricsPlayerData(
                    title: '無職転生',
                    cover: null,
                    isPlaying: false,
                    speed: 1,
                    lyricsMasked: false,
                    clock: _FakeClock(),
                  ),
                  callbacks: _callbacks(),
                  onHtmlThemeChanged: (_) {},
                )
              : const SizedBox.expand(),
        ),
      );

      await tester.pumpWidget(app(lyrics: true));
      await tester.pump(const Duration(milliseconds: 50));
      final Rect view = tester.getRect(find.byKey(lyricsKey));

      await _showAdded(tester);
      FushiMineNoticeCard card = tester.widget(
        find.byType(FushiMineNoticeCard),
      );
      expect(card.compact, isTrue);
      final Rect box = tester.getRect(find.byType(FushiMineNoticeCard));
      expect(box.left, moreOrLessEquals(view.left + 12, epsilon: 2));
      expect(box.top, moreOrLessEquals(view.bottom + 12, epsilon: 2));
      expect(box.overlaps(view), isFalse, reason: '小卡不能压在歌词上');
      await _drainToast(tester);

      // 歌词页上再推一个不透明页面：歌词页 offstage，不能贴到看不见的角上。
      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox.expand()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _showAdded(tester);
      card = tester.widget(find.byType(FushiMineNoticeCard));
      expect(card.compact, isFalse, reason: '歌词页被盖住时退回默认大卡');
      await _drainToast(tester);

      navKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _showAdded(tester);
      card = tester.widget(find.byType(FushiMineNoticeCard));
      expect(card.compact, isTrue, reason: '揭开后重新贴角');
      await _drainToast(tester);

      // 歌词页销毁：撤销登记。
      await tester.pumpWidget(app(lyrics: false));
      await tester.pump();
      await _showAdded(tester);
      card = tester.widget(find.byType(FushiMineNoticeCard));
      expect(card.compact, isFalse, reason: '歌词页销毁后撤销登记');
      await _drainToast(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
