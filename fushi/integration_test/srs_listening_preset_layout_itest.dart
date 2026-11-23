// BUG-5297：「加模板 › 听力」预设的正面在真 app 里认得出区块布局（Windows 离屏 runner）。
//
// 给内置 Fushi 卡片加两份听力模板：一份按现在的预设生成，一份是修复前预设手写的旧正面
// → 分别打开模板编辑页「可视化」页签，截图并断言没有「区块以外的代码被改过」警告；
// 再种一条带单词音频的笔记，打印每张卡的卡面路线（原生 / 回退原因）与正面自动播放清单
// （`[srs-listening]` 行）。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_listening_preset_layout_itest.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_fushi_card_plan.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_template_presets.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show templateNamesToIds;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_template_duplicates.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 修复前听力预设写的正面（名字形式，a5d5863e50 的 `_fushiListeningFront`）。
const String _legacyFront =
    '<div class="fc fc-front" lang="ja">\n'
    '  <div class="fc-front-audio">\n'
    '    <div class="fc-audio fc-audio--large">{{TermAudio}}</div>\n'
    '  </div>\n'
    '</div>\n';

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('听力预设正面：可视化页签认得出，复习走原生卡面并自动播放单词音频', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await _pumpFor(tester, const Duration(seconds: 1));

    final BuildContext rootContext = appModel.navigatorKey.currentContext!;
    final ProviderContainer container = ProviderScope.containerOf(rootContext);
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    await store.ensureBuiltins();
    final String typeId = store.fushiCardNoteTypeId;
    final SrsNoteTypeView type = (await store.noteType(typeId))!;

    final SrsTemplatePreset listening = srsTemplatePresets(type).firstWhere(
      (SrsTemplatePreset p) => p.kind == SrsTemplatePresetKind.listening,
    );
    expect(listening.available, isTrue);
    final String newId = await store.addTemplate(
      typeId,
      name: 'Listening',
      front: listening.front,
      back: listening.back,
    );
    final String legacyId = await store.addTemplate(
      typeId,
      name: 'Listening (old)',
      front: templateNamesToIds(_legacyFront, <String, String>{
        for (final SrsFieldDef f in type.fields) f.name: f.id,
      }),
      back: listening.back,
    );
    container.read(srsRevisionProvider.notifier).state++;

    Future<void> openVisual(String templateId, String shot) async {
      unawaited(
        appModel.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) => SrsTemplateEditorPage(
              noteTypeId: typeId,
              templateId: templateId,
              initialTab: SrsTemplateEditorTab.visual,
            ),
          ),
        ),
      );
      await _pumpFor(tester, const Duration(seconds: 4));
      final ObserveShot s = await captureFlutterFrame(tester, shot);
      expect(s.saved, isTrue);
      final bool panel = find
          .byKey(const ValueKey<String>('srs-fushi-block-layout-front'))
          .evaluate()
          .isNotEmpty;
      final bool warning = find
          .byKey(const ValueKey<String>('srs-fushi-layout-unrecognized'))
          .evaluate()
          .isNotEmpty;
      debugPrint('[srs-listening] $shot panel=$panel warning=$warning');
      expect(panel, isTrue, reason: '$shot：正面区块布局面板应已画出');
      expect(warning, isFalse, reason: '$shot：不应有「区块以外的代码被改过」');
      appModel.navigatorKey.currentState!.pop();
      await _pumpFor(tester, const Duration(seconds: 1));
    }

    await openVisual(newId, '01-listening-new-visual');
    await openVisual(legacyId, '02-listening-legacy-visual');

    final String uid = store.profileUid;
    final Map<String, String> fields = <String, String>{
      ...srsSampleCardFields(),
      'TermAudio': '[sound:word.mp3]',
      'SentenceAudio': '[sound:sentence.mp3]',
    };
    final String noteId = await store.createNote(
      noteTypeId: typeId,
      createdAt: 1700000000000,
      fieldsById: <String, String>{
        for (final MapEntry<String, String> e in fields.entries)
          srsFushiCardFieldId(uid, e.key): e.value,
      },
    );
    final Map<String, String> nameOf = <String, String>{
      for (final SrsTemplateDef t in (await store.noteType(typeId))!.templates)
        t.id: t.name,
    };
    for (final SrsCardCacheRow c in await store.cardsOfNote(noteId)) {
      if (c.templateId != newId && c.templateId != legacyId) continue;
      final SrsRenderedCard r = (await store.renderCard(c.id))!;
      final List<String> front = srsFushiCardPlan(
        r.fields,
        const SrsCardAppearance(),
        front: r.fushiCardFront,
        back: r.fushiCardBack,
      ).media.front;
      debugPrint(
        '[srs-listening] card "${nameOf[c.templateId]}" '
        'native=${r.nativeFallback == null} '
        'fallback=${r.nativeFallback?.code.name} '
        'frontItems=${r.fushiCardFront} frontAudio=$front',
      );
      expect(
        r.nativeFallback,
        isNull,
        reason: '${nameOf[c.templateId]} 应走原生卡面',
      );
      expect(front, <String>['word.mp3']);
    }

    // 新旧两份听力模板按区块布局是同一道题：判重认得出。
    final SrsNoteTypeView now = (await store.noteType(typeId))!;
    final List<String> twins = <String>[
      for (final SrsTemplateDef x in srsTemplatesWithSameFront(now, newId))
        x.name,
    ];
    debugPrint('[srs-listening] duplicates of "Listening": $twins');
    expect(twins, <String>['Listening (old)']);

    // 复习页只留新听力模板那张卡：看正面的大号发音键（真像素）。
    for (final SrsCardCacheRow c in await store.cardsOfNote(noteId)) {
      if (c.templateId != newId) await store.setSuspended(c.id, true);
    }
    container.read(srsRevisionProvider.notifier).state++;
    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              SrsReviewPage(deckId: store.defaultDeckId, deckName: 'listening'),
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 4));
    final ObserveShot review = await captureFlutterFrame(
      tester,
      '03-review-listening-front',
    );
    expect(review.saved, isTrue);
    final bool block = find
        .byKey(const ValueKey<String>('srs-fushi-front-item-0'))
        .evaluate()
        .isNotEmpty;
    debugPrint('[srs-listening] review front audio block=$block');
    expect(block, isTrue, reason: '复习页正面应画出大号发音键区块');
  });
}
