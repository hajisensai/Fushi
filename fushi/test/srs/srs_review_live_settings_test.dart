// 复习中从工具栏进牌组设置、改完回来，当前会话立即按新设置走：
// - BUG-3547：评分按钮上的间隔预览（学习步长）、顶栏计数（每日上限）、标题（改名）现读；
// - BUG-3546：自动播放开关同时管 `[sound:]`（宿主序列）与卡面页内媒体（SrsCardFace.autoplayMedia
//   → 卡面闸门），关掉后翻面不再自动播。
//
// 走真实路径：复习页工具栏「牌组设置」→ SrsDeckSettingsPage 改值 → 保存返回。
// 内存库 + 确定性假排程内核；widget 测试里没有 WebView，卡面换成纯文本实现并记下每次的 face。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 记下宿主序列播了什么（解析即文件名）。
class _RecordingAudio implements SrsCardAudioOutput {
  final List<String> played = <String>[];
  int stops = 0;

  @override
  Future<String?> resolve(String name) => Future<String?>.value(name);

  @override
  Future<bool> playToEnd(String path) {
    played.add(path);
    return Future<bool>.value(true);
  }

  @override
  Future<void> stop() async => stops++;
}

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<void> _addLapis(
  WidgetTester tester,
  SrsDbStore store,
  String expression, {
  Map<String, String> extra = const <String, String>{},
}) async {
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): expression,
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'meaning',
        for (final MapEntry<String, String> e in extra.entries)
          srsLapisFieldId(kSrsTestProfile, e.key): e.value,
      },
    ),
  );
}

/// 让真异步（drift）与帧都推进。
Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  required List<SrsCardFace> faces,
  required _RecordingAudio audio,
  Future<SrsDbStore?>? storeLoad,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith(
          (Ref ref) => storeLoad ?? Future<SrsDbStore?>.value(store),
        ),
        srsCardAudioOutputProvider.overrideWithValue(audio),
        srsCardFaceBuilderProvider.overrideWithValue((
          BuildContext context,
          SrsCardFace face,
        ) {
          faces.add(face);
          return SrsPlainCardFace(face: face);
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'Default'),
        ),
      ),
    ),
  );
  if (settle) await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// 复习页工具栏「牌组设置」（MD3 可能平铺，也可能收进 ⋯）。
Future<void> _openDeckSettings(WidgetTester tester) async {
  final Finder flat = find.byKey(
    const ValueKey<String>('srs_review_deck_settings'),
  );
  if (flat.evaluate().isNotEmpty) {
    await tester.tap(flat.first);
  } else {
    await tester.tap(
      find
          .byKey(const ValueKey<String>('fushi_floating_toolbar_overflow'))
          .first,
    );
    await _settle(tester);
    await tester.tap(find.text(t.srs_deck_settings).last);
  }
  await _settle(tester);
  expect(
    find.byKey(const ValueKey<String>('srs_settings_save')),
    findsWidgets,
    reason: '进了牌组设置页',
  );
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final Finder field = find.descendant(
    of: find.byKey(ValueKey<String>(key)),
    matching: find.byType(EditableText),
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> _saveSettings(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('srs_settings_save')).first,
  );
  await _settle(tester, rounds: 20);
}

/// 「重来」按钮上显示的间隔文字。
String _againLabel(WidgetTester tester) {
  final Finder texts = find.descendant(
    of: find.byKey(const ValueKey<String>('srs-rate-1')),
    matching: find.byType(Text),
  );
  return (tester.widget<Text>(texts.first)).data ?? '';
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('BUG-3579：首张卡还没出来就离开复习页，卸载不抛错、之后到达的卡不再上屏', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    final Completer<SrsDbStore?> load = Completer<SrsDbStore?>();
    final List<SrsCardFace> faces = <SrsCardFace>[];
    final _RecordingAudio audio = _RecordingAudio();
    await _pumpReview(
      tester,
      store: store,
      faces: faces,
      audio: audio,
      storeLoad: load.future,
      settle: false,
    );
    await tester.pump();
    expect(faces, isEmpty, reason: '牌组还在加载');
    // 用户等不及、直接返回：此前卸载时第一次初始化音频序列，ref.read 抛错、State 卡成僵尸。
    await _unmount(tester);
    expect(tester.takeException(), isNull);
    load.complete(store);
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(faces, isEmpty, reason: '离开后到达的卡不应再显示');
    expect(audio.played, isEmpty);
  });

  testWidgets('BUG-3547：复习中改学习步长 / 每日上限 / 名字，回来立即生效', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    await _addLapis(tester, store, '飲む');
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(
      tester,
      store: store,
      faces: faces,
      audio: _RecordingAudio(),
    );
    String counts(int n) =>
        '${t.srs_count_new} $n · ${t.srs_count_learn} 0 · '
        '${t.srs_count_review} 0';
    expect(find.text(counts(2)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);
    final String before = _againLabel(tester);
    expect(before, isNotEmpty);
    final String currentCard = faces.last.cardId;

    await _openDeckSettings(tester);
    // 按页面上的先后填（设置页是惰性列表，滚过去的字段会被回收）。
    await _type(tester, 'srs-settings-name', 'Renamed');
    await _type(tester, 'srs-settings-new', '1');
    await _type(tester, 'srs-settings-learn-steps', '25 60');
    await _saveSettings(tester);

    // 回到复习页：还是同一张卡、仍在答案面。
    expect(find.byType(SrsReviewPage), findsOneWidget);
    expect(faces.last.cardId, currentCard);
    expect(faces.last.showingAnswer, isTrue);

    // 「重来」的间隔按新学习步长（第一步 25 分钟）现算，而不是出题时缓存的旧值。
    final String expected = (await tester.runAsync(() async {
      final SrsAnswerPreview preview = await store.preview(currentCard);
      final SrsDayContext day = await store.dayContext();
      return srsIntervalLabel(
        srsIntervalParts(
          preview.plan[1],
          nowMs: preview.nowMs,
          today: day.dayIndexOf(preview.nowMs),
        ),
      );
    }))!;
    expect(_againLabel(tester), expected);
    expect(_againLabel(tester), isNot(before), reason: '预览不再是旧步长');
    // 计数按新的每日新卡上限（1）、标题按新名字。
    expect(find.text(counts(1)), findsOneWidget);
    expect(find.text('Renamed'), findsWidgets);
    await _unmount(tester);
  });

  testWidgets('BUG-3546：复习中关掉自动播放，卡面页内媒体与 [sound:] 都立即停止自动播放', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(
      tester,
      store,
      '食べる',
      extra: <String, String>{'ExpressionAudio': '[sound:word.mp3]'},
    );
    await _addLapis(
      tester,
      store,
      '飲む',
      extra: <String, String>{'ExpressionAudio': '[sound:drink.mp3]'},
    );
    await _addLapis(
      tester,
      store,
      '見る',
      extra: <String, String>{'ExpressionAudio': '[sound:see.mp3]'},
    );
    final List<SrsCardFace> faces = <SrsCardFace>[];
    final _RecordingAudio audio = _RecordingAudio();
    await _pumpReview(tester, store: store, faces: faces, audio: audio);
    expect(faces.last.autoplayMedia, isTrue, reason: '没设过 = 自动播（同 Anki）');

    // 对照：开关开着时翻面确实自动播 [sound:]（词汇卡出题面不含音频，答案面才有）。
    // 不成立的话，下面关掉后的 isEmpty 什么也证明不了。
    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);
    expect(audio.played, isNotEmpty, reason: '对照：开关开着时翻面自动播');
    await tester.tap(find.byKey(const ValueKey<String>('srs-rate-3')));
    await _settle(tester);
    final String secondCard = faces.last.cardId;
    expect(secondCard, isNot(faces.first.cardId), reason: '换到了第二张');

    await _openDeckSettings(tester);
    final Finder autoplay = find.byKey(
      const ValueKey<String>('srs-settings-autoplay-audio'),
    );
    await tester.ensureVisible(autoplay);
    await tester.tap(autoplay);
    await tester.pump();
    await _saveSettings(tester);

    expect(find.byType(SrsReviewPage), findsOneWidget);
    expect(
      faces.last.autoplayMedia,
      isFalse,
      reason: '当前这一面立即按新开关：卡面页内媒体不再自己播',
    );
    audio.played.clear();
    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);
    expect(audio.played, isEmpty, reason: '翻面不再自动播 [sound:]');
    expect(faces.last.autoplayMedia, isFalse);

    // 下一张（设置前就已预取好的那张）同样不自动播：预取快照随设置作废。
    await tester.tap(find.byKey(const ValueKey<String>('srs-rate-3')));
    await _settle(tester);
    expect(faces.last.showingAnswer, isFalse);
    expect(faces.last.cardId, isNot(secondCard), reason: '换到了下一张');
    expect(faces.last.autoplayMedia, isFalse);
    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);
    expect(audio.played, isEmpty, reason: '下一张翻面也不自动播');
    expect(faces.last.autoplayMedia, isFalse);
    // 手动「重播音频」照样能播（关的只是自动播放）。
    await tester.tap(
      find.byKey(const ValueKey<String>('srs_review_replay_audio')).first,
    );
    await _settle(tester);
    expect(audio.played, isNotEmpty);
    await _unmount(tester);
  });
}
