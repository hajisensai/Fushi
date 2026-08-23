import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:fushi/utils.dart';

/// BUG-1782：AniList 系列解析降级时，结果区必须**如实告知**结果可能横跨同系列多季。
///
/// 用户报的是「更新之后筛选怎么坏了 / 起了怪了，现在又行了，不知如何触发」——搜
/// `Yuru Yuri` 却把 `San Hai!` / `♪♪` / `Nachuyachumi!+` 一起平铺出来，过一会儿又正常。
/// 根因在 `AniListClient.searchAnime` 把 429 / 网络失败吞成空列表（见
/// `test/media/video/anilist_client_test.dart` 那组），此处只锁 UI 侧的契约：降级路径
/// 与正常路径在界面上**不能长得一模一样**，否则用户永远只能观察到「时好时坏」。
void main() {
  List<JimakuCandidate> crossSeasonCandidates() => const <JimakuCandidate>[
        // 复刻用户截图：同一次搜索里混着四个不同 entry 的文件。
        JimakuCandidate(
          entryName: 'Yuru Yuri',
          name: 'ゆるゆり.S01E01.中学デビュー!.WEBRip.Netflix.ja[cc].srt',
        ),
        JimakuCandidate(
          entryName: 'Yuru Yuri San Hai!',
          name: 'ゆるゆり さん ハイ!.S01E01.WEBRip.Netflix.ja[cc].srt',
        ),
        JimakuCandidate(
          entryName: 'Yuru Yuri Nachuyachumi!+',
          name: 'ゆるゆり なちゅやちゅみ＋.S01E01.WEBRip.Netflix.ja[cc].srt',
        ),
      ];

  Future<void> pump(
    WidgetTester tester, {
    required bool degraded,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => ElevatedButton(
              onPressed: () => showDialog<String>(
                context: ctx,
                builder: (_) => JimakuSubtitleDialog(
                  initialQuery: 'Yuru Yuri',
                  initialApiKey: 'TEST_KEY',
                  onApiKeyChanged: (_) async {},
                  saveDirectory: '/tmp/jimaku',
                  debugInitialCandidates: crossSeasonCandidates(),
                  debugInitialSeriesLookupFailed: degraded,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'), warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  testWidgets('AniList 没问上时，结果区如实告知可能混入其他季 + 给重试',
      (WidgetTester tester) async {
    await pump(tester, degraded: true);
    expect(tester.takeException(), isNull);

    expect(
      find.text(t.video_jimaku_series_lookup_degraded),
      findsOneWidget,
      reason: '降级路径必须说出来——否则用户只能观察到「筛选时好时坏」，'
          '而这正是本 bug 无法自查的原因',
    );
    expect(find.text(t.retry), findsOneWidget, reason: '降级是暂时的，必须能就地重试');
    // 提示不该顶掉结果本身：回退结果仍然有用，总比什么都不给强。
    expect(find.byType(JimakuCandidateList), findsOneWidget);
  });

  testWidgets('正常搜到时不显示降级提示（不吓唬用户）', (WidgetTester tester) async {
    await pump(tester, degraded: false);
    expect(tester.takeException(), isNull);
    expect(find.text(t.video_jimaku_series_lookup_degraded), findsNothing);
    expect(find.byType(JimakuCandidateList), findsOneWidget);
  });
}
