import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_dialog.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:material_ui/material_ui.dart';

import 'advanced_mining_test_host.dart';

/// 「高级制卡」的单词音频分区：列出每个启用音频源的候选、试听、选源 / 不要，确认时
/// 交出的 `wordAudioUrl`（null = 不改，与一键「+」等价；空串 = 不要；其余 = 那条
/// 音源**重新解析后**的 URL——互联源的令牌会过期，popup.js TODO-766 同一个坑）。
void main() {
  late FakeAdvancedMiningHost host;

  setUp(() => host = FakeAdvancedMiningHost());

  AdvancedMiningCapabilities caps() =>
      host.capabilities(deck: host.deck(), wordAudio: host.wordAudio());

  Future<AdvancedMiningController> loaded() async {
    final AdvancedMiningController c = AdvancedMiningController(caps());
    await c.load();
    return c;
  }

  group('控制器', () {
    test('打开即列出全部候选，默认选第一项（一键「+」用的那条）', () async {
      final AdvancedMiningController c = await loaded();
      expect(c.wordAudioLoaded, isTrue);
      expect(
        c.wordAudioChoices.map((AdvancedMiningWordAudioChoice e) => e.name),
        <String>['NHK', 'Forvo', 'Forvo'],
      );
      expect(c.wordAudioIndex, 0);
      expect(await c.resolveWordAudioUrl(), isNull);
    });

    test('选别的音源：确认时重新解析，交出同一源的新 URL', () async {
      final AdvancedMiningController c = await loaded();
      c.selectWordAudio(2);
      final String? url = await c.resolveWordAudioUrl();
      expect(host.wordAudioListCalls, 2, reason: '确认时必须重新解析一次');
      expect(url, 'https://audio.test/Forvo/strawberrybrown?token2');
    });

    test('重新解析找不到同一源：退回打开时那条', () async {
      final AdvancedMiningController c = await loaded();
      c.selectWordAudio(1);
      host.wordAudioSources = <(String, String)>[('NHK', '')];
      expect(
        await c.resolveWordAudioUrl(),
        'https://audio.test/Forvo/akitomo?token1',
      );
    });

    test('选「不要」：交空串；选回第一项就不写', () async {
      final AdvancedMiningController c = await loaded();
      c.selectWordAudio(AdvancedMiningController.kWordAudioOmitted);
      expect(c.omitWordAudio, isTrue);
      expect(await c.resolveWordAudioUrl(), '');
      c.selectWordAudio(0);
      expect(await c.resolveWordAudioUrl(), isNull);
    });

    test('试听：选中该项并播它的 URL', () async {
      final AdvancedMiningController c = await loaded();
      expect(await c.previewWordAudio(1), isTrue);
      expect(c.wordAudioIndex, 1);
      expect(host.wordAudioPreviews, <String>[
        'https://audio.test/Forvo/akitomo?token1',
      ]);
      expect(c.wordAudioPreviewing, isNull);
    });

    test('句子音频起播前停掉在响的单词发音；没播过就不去停', () async {
      final AdvancedMiningController c = AdvancedMiningController(
        host.capabilities(
          deck: host.deck(),
          wordAudio: host.wordAudio(),
          sentence: host.sentence(),
          audio: host.audio(),
        ),
      );
      await c.load();
      await c.togglePreview();
      expect(host.wordAudioStopCalls, 0, reason: '没播过单词发音，不该叫全局停止');
      await c.stopPreview();
      await c.previewWordAudio(0);
      await c.togglePreview();
      expect(host.wordAudioStopCalls, 1);
    });

    test('「恢复默认」：单词音频回到第一项', () async {
      final AdvancedMiningController c = await loaded();
      c.selectWordAudio(AdvancedMiningController.kWordAudioOmitted);
      await c.resetToDefaults();
      expect(c.wordAudioIndex, 0);
    });

    test('没有候选：只剩「不要」，确认不改', () async {
      host.wordAudioSources = <(String, String)>[];
      final AdvancedMiningController c = await loaded();
      expect(c.wordAudioChoices, isEmpty);
      expect(c.selectedWordAudio, isNull);
      expect(await c.resolveWordAudioUrl(), isNull);
    });
  });

  group('对话框', () {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    Future<void> open(
      WidgetTester tester, {
      Size size = const Size(1400, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      FushiToast.navigatorKey = navKey;
      final AdvancedMiningCapabilities c = caps();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => Center(
                child: TextButton(
                  onPressed: () => unawaited(
                    showAdvancedMiningDialog(context: ctx, capabilities: c),
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

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(
        find.text(t.popup_advanced_mining_confirm_to_deck(deck: '日语::挖矿')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出音源，点一行即试听并选中，确认交出该源', (WidgetTester tester) async {
      await open(tester);
      expect(
        find.text(t.popup_advanced_mining_word_audio_section),
        findsOneWidget,
      );
      expect(find.text('NHK'), findsOneWidget);
      expect(find.text('Forvo · akitomo'), findsOneWidget);
      await tester.tap(find.text('Forvo · akitomo'));
      await tester.pumpAndSettle();
      expect(host.wordAudioPreviews, hasLength(1));
      await confirm(tester);
      expect(host.confirmWordAudioUrls, <String?>[
        'https://audio.test/Forvo/akitomo?token2',
      ]);
    });

    testWidgets('不动直接确认：wordAudioUrl 为 null', (WidgetTester tester) async {
      await open(tester);
      await confirm(tester);
      expect(host.confirmWordAudioUrls, <String?>[null]);
    });

    testWidgets('选「不要」：确认交空串', (WidgetTester tester) async {
      await open(tester);
      await tester.tap(find.text(t.popup_advanced_mining_audio_none));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(host.confirmWordAudioUrls, <String?>['']);
    });

    testWidgets('窄屏有句子区时折叠成摘要行，显示选中的音源', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      FushiToast.navigatorKey = navKey;
      final AdvancedMiningCapabilities c = host.capabilities(
        deck: host.deck(),
        wordAudio: host.wordAudio(),
        sentence: host.sentence(),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => Center(
                child: TextButton(
                  onPressed: () => unawaited(
                    showAdvancedMiningDialog(context: ctx, capabilities: c),
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
      expect(
        find.text(t.popup_advanced_mining_word_audio_section),
        findsOneWidget,
      );
      expect(find.text('NHK'), findsOneWidget, reason: '摘要行显示当前选中的音源');
      expect(find.text('Forvo · akitomo'), findsNothing, reason: '折叠时不展开列表');
    });
  });
}
