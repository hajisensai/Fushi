import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';
import 'package:fushi/src/media/audiobook/tts/tts_read_along.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiChoiceRow;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/generate_test_epub.dart';
import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 朗读声音按「系列 + 语言」记（feat/read-aloud-series-voice）的设备层验收。
///
/// 场景（PR 描述里的化物語例子）：日文第 1 卷、中文第 1 卷、中文第 4 卷在同一个合集里，
/// 另有一本不属任何合集的中文书；默认声音「TTS JP」。全程经真阅读器：快捷键 B 开听书
/// 入口 → Enter「从这里朗读」→ 播放条声音按钮 → 快速切换对话框，全部焦点驱动。
///
///  1. 中文第 1 卷：入口显示默认声音；快速切换里说明「记到本系列的中文版」，选 TTS TW
///     → 朗读热切换到 TW；全局默认仍是 JP；作品表记在「合集 + zh」。
///  2. 日文第 1 卷：仍用 JP。
///  3. 中文第 4 卷：入口直接显示 TW，朗读用 TW；「使用默认声音」→ 回到 JP，作品表清空。
///  4. 不属合集的中文书：对话框说明「只记到这本书」，选 TW 只记这本。
///
/// Run (from fushi/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/read_aloud_series_voice_itest.dart

const String _jpVoice = 'itest-tts-jp';
const String _twVoice = 'itest-tts-tw';

void _log(String message) => debugPrint('[series-voice] $message');

bool _webViewShown() =>
    find.byKey(const ValueKey<String>('fushi_webview')).evaluate().isNotEmpty;

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int polls = 60,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (int i = 0; i < polls; i++) {
    if (done()) return true;
    await tester.pump(step);
  }
  return done();
}

TtsReadAlong? _readAlong(AppModel appModel) =>
    TtsReadAlong.forController(appModel.audiobookSession.controller);

Future<String> _importBook(AppModel appModel, String fileName) async {
  final String key = await EpubImporter.import(
    db: appModel.database,
    bytes: const EpubGenerator().generate(),
    fileName: fileName,
  );
  _log('imported $fileName -> $key');
  return key;
}

Future<void> _openBook(WidgetTester tester, String bookKey) async {
  await openBookViaProductionPath(tester, bookKey);
  expect(
    await _pumpUntil(tester, _webViewShown, polls: 120),
    isTrue,
    reason: 'reader WebView must mount for $bookKey',
  );
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _closeBook(WidgetTester tester, AppModel appModel) async {
  await appModel.audiobookSession.stop();
  await tester.pump(const Duration(milliseconds: 500));
  final Finder reader = find.byType(ReaderFushiPage);
  if (reader.evaluate().isNotEmpty) {
    Navigator.of(tester.element(reader)).pop();
  }
  expect(
    await _pumpUntil(
      tester,
      () => find.byType(ReaderFushiPage).evaluate().isEmpty,
    ),
    isTrue,
    reason: 'reader must close',
  );
  await tester.pump(const Duration(seconds: 1));
}

/// 把焦点 Tab 到 [text] 所在的选择行（[FushiChoiceRow]）上。
Future<bool> _focusRow(FocusDriver driver, Finder text) => driver.focusWidget(
  find.ancestor(of: text, matching: find.byType(FushiChoiceRow)).first,
);

/// 快捷键 B 开听书入口；断言入口上显示的声音名，再 Enter「从这里朗读」。
Future<void> _startReading(
  WidgetTester tester,
  AppModel appModel,
  FocusDriver driver, {
  required String expectedVoiceName,
  String? shot,
}) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
  final Finder readHere = find.text(t.audiobook_tts_read_from_here);
  expect(
    await _pumpUntil(tester, () => readHere.evaluate().isNotEmpty, polls: 20),
    isTrue,
    reason: 'listen entry dialog must open on B',
  );
  expect(
    find.text(expectedVoiceName),
    findsOneWidget,
    reason: 'listen entry must show the voice this book will use',
  );
  if (shot != null) await captureFlutterFrame(tester, shot);
  expect(await _focusRow(driver, readHere), isTrue);
  _log('focused: ${driver.focused?.debugLabel}');
  await driver.activate();
  await _pumpUntil(tester, () => readHere.evaluate().isEmpty, polls: 6);
  if (readHere.evaluate().isNotEmpty) {
    _log('entry still open after Enter; trying ActivateIntent');
    await driver.activateIntent();
  }
  final bool started = await _pumpUntil(
    tester,
    () => _readAlong(appModel) != null,
    polls: 120,
  );
  if (!started) {
    await captureFlutterFrame(tester, 'fail-start');
    _log(
      'start failed; dialog open=${readHere.evaluate().isNotEmpty} '
      'controller=${appModel.audiobookSession.controller} texts='
      '${find.byType(Text).evaluate().map((Element e) => (e.widget as Text).data).whereType<String>().take(40).join(' | ')}',
    );
  }
  expect(started, isTrue, reason: 'read-aloud session must start');
  await tester.pump(const Duration(seconds: 1));
}

/// 播放条声音按钮 → 快速切换对话框；断言顶部说明，选 [label] 那一项。
Future<void> _quickSwitch(
  WidgetTester tester,
  FocusDriver driver, {
  required String expectedMessage,
  required String label,
  String? shot,
}) async {
  // 播放条只在工具栏唤出时画；朗读中按 B 开有声书面板，面板里同一个换声音入口。
  final Finder barButton = find.byKey(
    const ValueKey<String>('fushi_play_bar_tts_voice_switch'),
  );
  final Finder panelChip = find.byKey(
    const ValueKey<String>('fushi_audiobook_panel_tts_voice_switch'),
  );
  if (barButton.evaluate().isEmpty) {
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    expect(
      await _pumpUntil(
        tester,
        () => panelChip.evaluate().isNotEmpty,
        polls: 20,
      ),
      isTrue,
      reason: 'B while reading aloud must open the audiobook panel voice chip',
    );
    expect(await driver.focusWidget(panelChip), isTrue);
  } else {
    expect(await driver.focusWidget(barButton), isTrue);
  }
  await driver.activate();
  final Finder message = find.text(expectedMessage);
  expect(
    await _pumpUntil(tester, () => message.evaluate().isNotEmpty, polls: 20),
    isTrue,
    reason: 'quick switch must say where the pick is saved: $expectedMessage',
  );
  if (shot != null) await captureFlutterFrame(tester, shot);
  final Finder option = find.text(label);
  expect(option, findsOneWidget, reason: 'option "$label" must be listed');
  expect(await _focusRow(driver, option), isTrue);
  await driver.activate();
  expect(
    await _pumpUntil(tester, () => message.evaluate().isEmpty, polls: 20),
    isTrue,
    reason: 'dialog must close after picking',
  );
}

Future<void> _expectReadingVoice(
  WidgetTester tester,
  AppModel appModel,
  String presetId,
) async {
  final bool ok = await _pumpUntil(
    tester,
    () => _readAlong(appModel)?.preset.id == presetId,
    polls: 40,
  );
  expect(
    ok,
    isTrue,
    reason:
        'read-aloud must use $presetId (got ${_readAlong(appModel)?.preset.id})',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('read-aloud voice is remembered per series + language', (
    WidgetTester tester,
  ) async {
    await runFushiItest(
      label: 'series-voice',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));
        final AppModel appModel = await readyAppModel(tester);
        await appModel.setExperimentalFocusNavigationEnabled(true);
        for (int i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await showBooksTab(tester);
        final FocusDriver driver = FocusDriver(tester);

        // 两个系统语音预设（离线可用）；默认 JP。
        final TtsServices tts = TtsServices.of(appModel.prefsRepo);
        await tts.store.savePresets(const <TtsVoicePreset>[
          TtsVoicePreset(
            id: _jpVoice,
            providerId: SystemTtsDescriptor.providerId,
            name: 'TTS JP',
          ),
          TtsVoicePreset(
            id: _twVoice,
            providerId: SystemTtsDescriptor.providerId,
            name: 'TTS TW',
          ),
        ]);
        await tts.store.setActivePresetId(_jpVoice);
        await tts.store.saveMediaVoices(TtsMediaVoices());

        // 书：日文 1、中文 1、中文 4 进同一个合集；另一本中文书不进合集。
        final FushiDatabase db = appModel.database;
        final String jp1 = await _importBook(appModel, 'bake_jp_1.epub');
        final String zh1 = await _importBook(appModel, 'bake_zh_1.epub');
        final String zh4 = await _importBook(appModel, 'bake_zh_4.epub');
        final String solo = await _importBook(appModel, 'three_body.epub');
        await db.updateEpubBookLanguage(jp1, 'ja');
        await db.updateEpubBookLanguage(zh1, 'zh-Hant');
        await db.updateEpubBookLanguage(zh4, 'zh-TW');
        await db.updateEpubBookLanguage(solo, 'zh');
        final int collection = await db.createMediaCollection(
          'Bakemonogatari itest',
        );
        for (final String key in <String>[jp1, zh1, zh4]) {
          await db.addToCollection(collection, MediaKind.epub, key);
        }
        final String seriesKey = 'collection:$collection';

        // 1. 中文第 1 卷：默认 JP → 换 TW，记到「合集 + zh」。
        await _openBook(tester, zh1);
        await _startReading(
          tester,
          appModel,
          driver,
          expectedVoiceName: 'TTS JP',
        );
        await _expectReadingVoice(tester, appModel, _jpVoice);
        await _quickSwitch(
          tester,
          driver,
          expectedMessage: t.audiobook_tts_voice_scope_series_language(
            language: contentLanguageLabelOf('zh-Hant'),
          ),
          label: 'TTS TW',
          shot: '01-zh1-quick-switch',
        );
        await _expectReadingVoice(tester, appModel, _twVoice);
        expect(tts.store.activePresetId, _jpVoice, reason: '全局默认不变');
        expect(tts.store.loadMediaVoices().series[seriesKey], <String, String>{
          'zh': _twVoice,
        });
        _log('step 1 ok: zh1 switched to TW, saved for $seriesKey/zh');
        await _closeBook(tester, appModel);

        // 2. 日文第 1 卷：仍是 JP。
        await _openBook(tester, jp1);
        await _startReading(
          tester,
          appModel,
          driver,
          expectedVoiceName: 'TTS JP',
        );
        await _expectReadingVoice(tester, appModel, _jpVoice);
        _log('step 2 ok: jp1 still JP');
        await _closeBook(tester, appModel);

        // 3. 中文第 4 卷：直接 TW；「使用默认声音」→ JP，作品表清空。
        await _openBook(tester, zh4);
        await _startReading(
          tester,
          appModel,
          driver,
          expectedVoiceName: 'TTS TW',
          shot: '02-zh4-listen-entry',
        );
        await _expectReadingVoice(tester, appModel, _twVoice);
        await _quickSwitch(
          tester,
          driver,
          expectedMessage: t.audiobook_tts_voice_scope_series_language(
            language: contentLanguageLabelOf('zh-TW'),
          ),
          label: t.audiobook_tts_voice_use_default,
          shot: '03-zh4-quick-switch',
        );
        await _expectReadingVoice(tester, appModel, _jpVoice);
        expect(tts.store.loadMediaVoices().isEmpty, isTrue);
        _log('step 3 ok: zh4 inherited TW, use-default restored JP');
        await _closeBook(tester, appModel);

        // 4. 不属合集的书：只记这本。
        await _openBook(tester, solo);
        await _startReading(
          tester,
          appModel,
          driver,
          expectedVoiceName: 'TTS JP',
        );
        await _quickSwitch(
          tester,
          driver,
          expectedMessage: t.audiobook_tts_voice_scope_book,
          label: 'TTS TW',
          shot: '04-solo-quick-switch',
        );
        await _expectReadingVoice(tester, appModel, _twVoice);
        final TtsMediaVoices after = tts.store.loadMediaVoices();
        expect(after.books, <String, String>{solo: _twVoice});
        expect(after.series, isEmpty);
        _log('step 4 ok: standalone book saved for itself only');
        await _closeBook(tester, appModel);
        _log('ALL STEPS PASSED');
      },
    );
  });
}
