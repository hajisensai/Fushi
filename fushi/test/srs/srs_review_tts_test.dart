// 复习朗读（拍板台 YmWT1x57XV）在真实复习页上的接线：
// - 选中文字后底栏上方出「朗读」键，点了按选中的文字合成、交给卡面的播放序列；关掉就不出键、不上报选区；
// - 「没有音频的字段显示朗读键」改了立即生效：当前这张原地重渲，空的 SentenceAudio 换成朗读键。
//
// 走真实复习页 + 内存库；widget 测试里没有 WebView，卡面换成纯文本实现并记下每次的 face。合成换成
// 不碰磁盘的替身（缓存与落盘见 srs_card_tts_audio_test.dart）。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_tts_sheet.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_card_tts_audio.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_edit.dart';
import 'package:fushi/src/srs/srs_review_tts.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_card_tts.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 记下序列要播的名字（不碰真播放器）。
class _RecordingAudio implements SrsCardAudioOutput {
  final List<String> resolved = <String>[];

  @override
  Future<String?> resolve(String name) {
    resolved.add(name);
    return Future<String?>.value('fake.wav');
  }

  @override
  Future<bool> playToEnd(String path) => Future<bool>.value(true);

  @override
  Future<void> stop() async {}
}

/// 不碰磁盘的合成替身：记下念了什么。
class _FakeTts extends SrsCardTtsAudio {
  _FakeTts()
    : super(
        plan: (SrsTtsSound s) => throw UnimplementedError(),
        synthesize: (SrsTtsPlan plan, Directory out) =>
            throw UnimplementedError(),
        scratch: () => throw UnimplementedError(),
      );

  final List<String> spoken = <String>[];

  @override
  Future<File?> fileFor(SrsTtsSound sound, SrsMediaStore store) async {
    spoken.add(sound.text);
    return File('fake.wav');
  }
}

final StateProvider<SrsReviewTts> _tts = StateProvider<SrsReviewTts>(
  (Ref ref) => const SrsReviewTts(),
);

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  await srsSettle(tester, minRounds: rounds);
}

Future<SrsDbStore> _seed(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '試合',
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'a formal match',
        srsLapisFieldId(kSrsTestProfile, 'Sentence'): '明日は試合がある。',
      },
    ),
  );
  return store;
}

Future<ProviderContainer> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  required List<SrsCardFace> faces,
  required _RecordingAudio audio,
  required _FakeTts tts,
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
          (Ref ref) => Future<SrsDbStore?>.value(store),
        ),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => SrsMediaStore(Directory.systemTemp),
        ),
        srsCardAudioOutputProvider.overrideWithValue(audio),
        srsCardTtsAudioProvider.overrideWithValue(tts),
        srsReviewChromeFloatingProvider.overrideWithValue(false),
        srsReviewInlineEditProvider.overrideWithValue(false),
        srsReviewTtsProvider.overrideWith((Ref ref) => ref.watch(_tts)),
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
  await _settle(tester);
  return ProviderScope.containerOf(tester.element(find.byType(SrsReviewPage)));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

final Finder _speakKey = find.byKey(
  const ValueKey<String>('srs-review-speak-selection'),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('selecting text shows a speak key; tapping it synthesizes the '
      'selection and plays it through the card sequence', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _seed(tester);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    final _RecordingAudio audio = _RecordingAudio();
    final _FakeTts tts = _FakeTts();
    await _pumpReview(
      tester,
      store: store,
      faces: faces,
      audio: audio,
      tts: tts,
    );
    expect(faces.last.onEditSelection, isNotNull, reason: '朗读选区要选区上报');
    expect(_speakKey, findsNothing, reason: '没选中文字时不出键');

    faces.last.onEditSelection!(
      const SrsCardSelection('明日は試合', speech: '明日は 試合'),
    );
    await _settle(tester);
    expect(_speakKey, findsOneWidget);

    audio.resolved.clear();
    await tester.tap(_speakKey);
    await _settle(tester);
    expect(tts.spoken, <String>['明日は 試合']);
    final List<SrsTtsSound> played = <SrsTtsSound>[
      for (final String n in audio.resolved) ?SrsTtsSound.parse(n),
    ];
    expect(played.map((SrsTtsSound s) => s.text), <String>['明日は 試合']);
    await _unmount(tester);
  });

  testWidgets('speak selection off: no speak key and the card face does not '
      'report selections', (WidgetTester tester) async {
    final SrsDbStore store = await _seed(tester);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    final ProviderContainer c = await _pumpReview(
      tester,
      store: store,
      faces: faces,
      audio: _RecordingAudio(),
      tts: _FakeTts(),
    );
    c.read(_tts.notifier).state = const SrsReviewTts(speakSelection: false);
    await _settle(tester);
    expect(faces.last.onEditSelection, isNull);
    expect(_speakKey, findsNothing);
    await _unmount(tester);
  });

  testWidgets('turning on read-aloud buttons for fields without audio '
      're-renders the current card: empty SentenceAudio becomes a TTS key', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _seed(tester);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    final ProviderContainer c = await _pumpReview(
      tester,
      store: store,
      faces: faces,
      audio: _RecordingAudio(),
      tts: _FakeTts(),
    );
    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);
    expect(faces.last.showingAnswer, isTrue);
    expect(faces.last.bodyHtml, isNot(contains(kSrsTtsSoundPrefix)));

    c.read(_tts.notifier).state = const SrsReviewTts(fillMissing: true);
    await _settle(tester);
    expect(faces.last.showingAnswer, isTrue, reason: '原地重渲，仍在答案面');
    final Match? m = RegExp(
      r'\[sound:(fushi-tts:[^\]]+)\]',
    ).firstMatch(faces.last.bodyHtml);
    expect(m, isNotNull, reason: '空的例句音频换成朗读键');
    expect(SrsTtsSound.parse(m!.group(1)!)!.text, '明日は試合がある。');
    await _unmount(tester);
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';
    testWidgets('[$ds] read-aloud sheet: switches write back; the field '
        'picker only shows while fill is on', (WidgetTester tester) async {
      final List<SrsReviewTts> written = <SrsReviewTts>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              designSystem: apple
                  ? FushiDesignSystem.cupertino
                  : FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: apple,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: Scaffold(
              body: SingleChildScrollView(
                child: SrsReviewTtsSheet(
                  initial: const SrsReviewTts(),
                  onChanged: written.add,
                  voiceSummary: () => 'System voice',
                  pickVoice: (BuildContext context) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder fields = find.byKey(
        const ValueKey<String>('srs-review-tts-fields'),
      );
      expect(fields, findsNothing);
      expect(
        find.byKey(const ValueKey<String>('srs-review-tts-cache-note')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('srs-review-tts-fill')),
      );
      await tester.pumpAndSettle();
      expect(written.last.fillMissing, isTrue);
      expect(written.last.renderOptions.fillAudioFields, <String>{
        kSrsSentenceAudioField,
      });
      expect(fields, findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('srs-review-tts-selection')),
      );
      await tester.pumpAndSettle();
      expect(written.last.speakSelection, isFalse);
      expect(written.last.fillMissing, isTrue, reason: '前一项改动保留');
    });
  }
}
