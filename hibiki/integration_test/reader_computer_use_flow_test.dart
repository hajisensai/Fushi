import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart'
    show GamepadButton, ModifierKey;
import 'package:hibiki/src/shortcuts/reader_space_override.dart'
    show resolveReaderArrowPageTurn;
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

const String _testword = 'testword';
const String _cat = '\u732b';
const String _testwordGloss =
    'Generated dictionary entry used by comprehensive tests.';
const String _catGloss =
    'Generated Japanese lookup entry for comprehensive tests.';

/// TODO-519: Computer Use / real-app reader flow.
///
/// This is the automated acceptance layer for the visible Computer Use checklist:
/// it drives the true Flutter app with FocusDriver + tester.sendKeyEvent only.
/// Page turns go through the reader shortcut registry; dictionary lookup goes
/// through the reader char caret and popup WebView, never direct selection hooks.
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'reader keyboard page stress and repeated caret dictionary lookups',
    timeout: const Timeout(Duration(minutes: 8)),
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = [];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[CU] FlutterError: ${details.exceptionAsString()}');
      };

      try {
        app.main();
        expect(await waitForHome(tester), isTrue, reason: 'Home must render');
        await tester.pump(const Duration(seconds: 2));

        final FocusDriver driver = FocusDriver(tester);
        final AppModel appModel = await readyAppModel(tester);
        await _enableFocusNavigation(tester, appModel);
        await _ensureLookupDictionary(tester, appModel);

        final String bookKey = await seedReaderBook(
          tester,
          fileName: 'todo519_computer_use.epub',
        );
        await _openSeededBook(tester, driver, bookKey);

        final Future<dynamic> Function(String source) eval =
            await _waitForReaderReady(tester);
        _focusReaderSurface(tester);

        _assertPageShortcutBindings(appModel);
        await _runPageTurnStress(tester, eval);
        await _runRepeatedLookupStress(tester, eval);

        await takeScreenshot(binding, 'reader_computer_use_flow_verified');

        final NavigatorState nav =
            Navigator.of(tester.element(find.byType(Scaffold).first));
        nav.pop();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();

        assertStrictErrors(errors);
        debugPrint('[CU] === COMPUTER USE READER FLOW PASSED ===');
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}

Future<void> _enableFocusNavigation(
  WidgetTester tester,
  AppModel appModel,
) async {
  if (appModel.experimentalFocusNavigationEnabled) return;
  await appModel.setExperimentalFocusNavigationEnabled(true);
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _ensureLookupDictionary(
  WidgetTester tester,
  AppModel appModel,
) async {
  if (await _hasLookupEntry(appModel, _testword, _testwordGloss) &&
      await _hasLookupEntry(appModel, _cat, _catGloss)) {
    return;
  }

  await seedDictionary(tester);
  if (await _hasLookupEntry(appModel, _testword, _testwordGloss) &&
      await _hasLookupEntry(appModel, _cat, _catGloss)) {
    return;
  }

  final Directory cacheDir = await getTemporaryDirectory();
  final File generated = File('${cacheDir.path}/todo519_generated_dict.zip');
  await writeGeneratedDictionary(generated);

  final ValueNotifier<String> progress = ValueNotifier<String>('');
  final Completer<void> imported = Completer<void>();
  try {
    await appModel.importDictionary(
      file: generated,
      progressNotifier: progress,
      onImportSuccess: () {
        if (!imported.isCompleted) imported.complete();
      },
    );
    await imported.future.timeout(const Duration(seconds: 90));
  } finally {
    progress.dispose();
  }
  await tester.pump(const Duration(seconds: 1));

  expect(await _hasLookupEntry(appModel, _testword, _testwordGloss), isTrue,
      reason: 'fixture dictionary must resolve $_testword');
  expect(await _hasLookupEntry(appModel, _cat, _catGloss), isTrue,
      reason: 'fixture dictionary must resolve $_cat');
}

Future<bool> _hasLookupEntry(
  AppModel appModel,
  String term,
  String expectedGloss,
) async {
  final result = await appModel.searchDictionary(
    searchTerm: term,
    searchWithWildcards: false,
  );
  if (result.entries.any((entry) =>
      entry.word == term &&
      (entry.meaning.contains(expectedGloss) ||
          entry.dictionaryName == 'HibikiGeneratedTestDict'))) {
    return true;
  }
  return result.popupJson?.contains(expectedGloss) ?? false;
}

Future<void> _openSeededBook(
  WidgetTester tester,
  FocusDriver driver,
  String bookKey,
) async {
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  expect(navTargets, isNotEmpty, reason: 'primary navigation must be present');
  final bool focusedBooks = await driver.focusWidget(navTargets.first);
  expect(focusedBooks, isTrue, reason: 'Books tab must be reachable by focus');
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 500));

  final String seededEntryKey =
      'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
  final Finder seededEntry = find.byKey(ValueKey<String>(seededEntryKey));
  for (int i = 0; i < 40 && seededEntry.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(seededEntry, findsOneWidget,
      reason: 'seeded Computer Use EPUB must appear on the shelf');

  final bool focusedBook = await driver.focusWidget(seededEntry);
  expect(focusedBook, isTrue, reason: 'seeded book must be focus reachable');
  if (!await driver.activateIntent()) {
    expect(
      await driver.requestFocusInside(
        seededEntry,
        debugLabelContains: 'reader-shelf-book-',
      ),
      isTrue,
      reason: 'seeded book must expose a concrete shelf Focus node',
    );
    expect(await driver.activateIntent(), isTrue,
        reason: 'seeded book focus must expose ActivateIntent');
  }
  await tester.pump(const Duration(seconds: 3));
}

Future<Future<dynamic> Function(String source)> _waitForReaderReady(
  WidgetTester tester,
) async {
  const Key webViewKey = ValueKey<String>('hoshi_webview');
  for (int i = 0; i < 80 && find.byKey(webViewKey).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(find.byKey(webViewKey), findsOneWidget, reason: 'WebView must mount');

  const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
  for (int i = 0;
      i < 140 && find.byKey(contentReadyKey).evaluate().isEmpty;
      i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(find.byKey(contentReadyKey), findsOneWidget,
      reason: 'Reader content must become ready');
  await tester.pump(const Duration(seconds: 3));

  final eval = ReaderHibikiPage.debugEvaluateJavascript;
  expect(eval, isNotNull,
      reason: 'Reader debug JS hook must be available in integration runs');
  return eval!;
}

void _focusReaderSurface(WidgetTester tester) {
  final Finder webView = find.byKey(const ValueKey<String>('hoshi_webview'));
  final Iterable<Element> matches = webView.evaluate();
  expect(matches, isNotEmpty, reason: 'Reader WebView must be mounted');
  bool focused = false;
  matches.single.visitAncestorElements((Element ancestor) {
    final Widget widget = ancestor.widget;
    if (widget is Focus && widget.onKeyEvent != null) {
      widget.focusNode?.requestFocus();
      focused = true;
      return false;
    }
    return true;
  });
  expect(focused, isTrue, reason: 'Reader key-event Focus must wrap WebView');
}

void _assertPageShortcutBindings(AppModel appModel) {
  expect(
    appModel.shortcutRegistry.resolveKeyboard(
      LogicalKeyboardKey.pageDown,
      modifiers: const <ModifierKey>{},
      scope: ShortcutScope.reader,
    ),
    ShortcutAction.readerPageForward,
    reason: 'PageDown must resolve through readerPageForward before stress',
  );
  expect(
    appModel.shortcutRegistry.resolveGamepad(
      GamepadButton.rb,
      scope: ShortcutScope.reader,
    ),
    ShortcutAction.readerPageForward,
    reason: 'Gamepad RB must resolve through readerPageForward before stress',
  );
  expect(
    appModel.shortcutRegistry.resolveKeyboard(
      LogicalKeyboardKey.arrowRight,
      modifiers: const <ModifierKey>{},
      scope: ShortcutScope.reader,
    ),
    ShortcutAction.readerPageForward,
    reason: 'ArrowRight must resolve through readerPageForward before stress',
  );
  expect(
    resolveReaderArrowPageTurn(
      key: LogicalKeyboardKey.arrowLeft,
      modifiers: const <ModifierKey>{},
      rtl: true,
    ),
    ShortcutAction.readerPageForward,
    reason: 'vertical-rl fixture must map ArrowLeft to readerPageForward',
  );
  expect(
    appModel.shortcutRegistry.resolveKeyboard(
      LogicalKeyboardKey.pageUp,
      modifiers: const <ModifierKey>{},
      scope: ShortcutScope.reader,
    ),
    ShortcutAction.readerPageBackward,
    reason: 'PageUp must resolve through readerPageBackward before stress',
  );
  expect(
    appModel.shortcutRegistry.resolveKeyboard(
      LogicalKeyboardKey.arrowLeft,
      modifiers: const <ModifierKey>{},
      scope: ShortcutScope.reader,
    ),
    ShortcutAction.readerPageBackward,
    reason: 'ArrowLeft must resolve through readerPageBackward before stress',
  );
  expect(
    appModel.shortcutRegistry.resolveKeyboard(
      LogicalKeyboardKey.space,
      modifiers: const <ModifierKey>{ModifierKey.shift},
      scope: ShortcutScope.reader,
    ),
    ShortcutAction.readerPageBackward,
    reason: 'Shift+Space must resolve through readerPageBackward before stress',
  );
  expect(
    appModel.shortcutRegistry.resolveGamepad(
      GamepadButton.lb,
      scope: ShortcutScope.reader,
    ),
    ShortcutAction.readerPageBackward,
    reason: 'Gamepad LB must resolve through readerPageBackward before stress',
  );
  expect(
    resolveReaderArrowPageTurn(
      key: LogicalKeyboardKey.arrowRight,
      modifiers: const <ModifierKey>{},
      rtl: true,
    ),
    ShortcutAction.readerPageBackward,
    reason: 'vertical-rl fixture must map ArrowRight to readerPageBackward',
  );
}

Future<void> _runPageTurnStress(
  WidgetTester tester,
  Future<dynamic> Function(String source) eval,
) async {
  ReaderPageSnapshot state = await _readPageState(eval);
  expect(state.ready, isTrue, reason: 'window.hoshiReader must be ready');
  if (state.currentPage != null && state.totalPages != null) {
    expect(state.totalPages! - state.currentPage!, greaterThanOrEqualTo(25),
        reason: 'fixture chapter must have enough pages for 20 forward + '
            '5 backward user-key turns');
  }
  debugPrint('[CU] page start: $state');

  for (int i = 0; i < 20; i++) {
    state = await _sendPageTurnAndWait(
      tester,
      eval,
      key: LogicalKeyboardKey.pageDown,
      before: state,
      forward: true,
      label: 'forward ${i + 1}/20',
    );
  }
  final ReaderPageSnapshot afterForward = state;
  debugPrint('[CU] page after 20 forward turns: $afterForward');

  for (int i = 0; i < 5; i++) {
    state = await _sendPageTurnAndWait(
      tester,
      eval,
      key: LogicalKeyboardKey.pageUp,
      before: state,
      forward: false,
      label: 'backward ${i + 1}/5',
    );
  }
  debugPrint('[CU] page after 5 backward turns: $state');

  expect(state.isBefore(afterForward), isTrue,
      reason: 'five readerPageBackward key presses must move back from the '
          '20-forward point');
}

Future<ReaderPageSnapshot> _sendPageTurnAndWait(
  WidgetTester tester,
  Future<dynamic> Function(String source) eval, {
  required LogicalKeyboardKey key,
  bool shift = false,
  required ReaderPageSnapshot before,
  required bool forward,
  required String label,
}) async {
  _focusReaderSurface(tester);
  await tester.pump(const Duration(milliseconds: 50));
  debugPrint('[CU] send $label key=${key.debugName} shift=$shift '
      'input=${_debugInputState()}');
  await _sendUserKeyEvent(tester, key, shift: shift);
  debugPrint('[CU] sent $label input=${_debugInputState()}');
  ReaderPageSnapshot latest = before;
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 150));
    latest = await _readPageState(eval);
    if (forward ? latest.isAfter(before) : latest.isBefore(before)) {
      final ReaderPageSnapshot settled =
          await _waitForPageTurnSettle(tester, eval, latest);
      debugPrint('[CU] page $label -> $settled');
      return settled;
    }
  }
  fail(
      'Page key did not produce ${forward ? "readerPageForward" : "readerPageBackward"} '
      'state change for $label. input=${_debugInputState()} '
      'before=$before latest=$latest');
}

String _debugInputState() {
  final FocusNode? focus = FocusManager.instance.primaryFocus;
  final String focusText = focus == null ? 'null' : focus.toStringShort();
  final Iterable<String> pressed = HardwareKeyboard.instance.logicalKeysPressed
      .map((LogicalKeyboardKey key) => key.debugName ?? key.keyLabel)
      .where((String label) => label.isNotEmpty);
  return 'focus=$focusText shift=${HardwareKeyboard.instance.isShiftPressed} '
      'pressed=[${pressed.join(",")}]';
}

Future<ReaderPageSnapshot> _waitForPageTurnSettle(
  WidgetTester tester,
  Future<dynamic> Function(String source) eval,
  ReaderPageSnapshot first,
) async {
  ReaderPageSnapshot previous = first;
  int stableReads = 0;
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    final ReaderPageSnapshot next = await _readPageState(eval);
    if (next.sameLocation(previous)) {
      stableReads++;
      if (stableReads >= 2) {
        await tester.pump(const Duration(milliseconds: 250));
        return next;
      }
    } else {
      stableReads = 0;
      previous = next;
    }
  }
  await tester.pump(const Duration(milliseconds: 250));
  return previous;
}

Future<void> _sendUserKeyEvent(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  try {
    await tester.sendKeyEvent(key);
  } finally {
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
}

Future<ReaderPageSnapshot> _readPageState(
  Future<dynamic> Function(String source) eval,
) async {
  const String source = r'''
JSON.stringify((function() {
  var r = window.hoshiReader;
  if (!r) return {ready:false};
  var ctx = r.getScrollContext ? r.getScrollContext() : null;
  var metrics = r.paginationMetrics ||
      (r.buildPaginationMetrics ? r.buildPaginationMetrics() : null);
  var info = r.pageInfo ? r.pageInfo() : null;
  var scroll = ctx && r.getPagePosition ? r.getPagePosition(ctx) : 0;
  return {
    ready: true,
    scroll: Math.round(scroll || 0),
    columnPitch: Math.round((ctx && ctx.columnPitch) || 0),
    maxScroll: Math.round((metrics && metrics.maxScroll) || 0),
    minScroll: Math.round((metrics && metrics.minScroll) || 0),
    currentPage: info ? info.currentPage : null,
    totalPages: info ? info.totalPages : null,
    firstVisibleCharOffset: r.getFirstVisibleCharOffset ?
        r.getFirstVisibleCharOffset() : null,
    progress: r.calculateProgress ? r.calculateProgress() : null,
    vertical: ctx ? !!ctx.vertical : null
  };
})())
''';
  final raw = await eval(source);
  return ReaderPageSnapshot.fromJson(
    jsonDecode(raw as String) as Map<String, dynamic>,
  );
}

Future<void> _runRepeatedLookupStress(
  WidgetTester tester,
  Future<dynamic> Function(String source) eval,
) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _waitForReaderCaret(tester, eval);

  const List<({String term, String gloss})> rounds = [
    (term: _testword, gloss: _testwordGloss),
    (term: _cat, gloss: _catGloss),
    (term: _testword, gloss: _testwordGloss),
    (term: _cat, gloss: _catGloss),
    (term: _testword, gloss: _testwordGloss),
  ];

  String? previousSignature;
  for (int i = 0; i < rounds.length; i++) {
    final round = rounds[i];
    final CaretSnapshot caret = await _moveCaretToTerm(
      tester,
      eval,
      round.term,
      skipCurrent: i > 0,
    );
    debugPrint('[CU] lookup round ${i + 1}: caret=$caret');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final PopupSnapshot popup = await _waitForPopupResult(
      tester,
      expectedTerm: round.term,
      expectedGloss: round.gloss,
    );
    debugPrint('[CU] lookup round ${i + 1}: popup=$popup');

    expect(popup.signature == previousSignature, isFalse,
        reason: 'lookup round ${i + 1} must not reuse previous popup result');
    previousSignature = popup.signature;

    await _closePopupAndReturnToReader(tester);
  }
}

Future<CaretSnapshot> _waitForReaderCaret(
  WidgetTester tester,
  Future<dynamic> Function(String source) eval,
) async {
  CaretSnapshot? latest;
  for (int i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 150));
    latest = await _readCaret(eval);
    if (latest.active && latest.surface == 'reader') {
      return latest;
    }
  }
  fail('Enter did not move the reader into caret mode. latest=$latest');
}

Future<CaretSnapshot> _moveCaretToTerm(
  WidgetTester tester,
  Future<dynamic> Function(String source) eval,
  String expectedTerm, {
  required bool skipCurrent,
}) async {
  if (skipCurrent) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 150));
  }

  CaretSnapshot latest = await _readCaret(eval);
  for (int i = 0; i < 800; i++) {
    latest = await _readCaret(eval);
    if (latest.active &&
        latest.surface == 'reader' &&
        latest.isOnTerm(expectedTerm)) {
      return latest;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 120));
  }
  fail('Could not move reader caret to "$expectedTerm". latest=$latest');
}

Future<CaretSnapshot> _readCaret(
  Future<dynamic> Function(String source) eval,
) async {
  const String source = r'''
JSON.stringify((function() {
  var c = window.hoshiCaret;
  var node = c && c.node;
  var text = node && node.textContent ? node.textContent : '';
  var off = c && typeof c.offset === 'number' ? c.offset : -1;
  return {
    active: !!(c && c.isActive && c.isActive()),
    offset: off,
    text: text,
    ch: off >= 0 ? text.substr(off, 1) : '',
    around: off >= 0 ? text.substring(Math.max(0, off - 16), off + 32) : ''
  };
})())
''';
  final raw = await eval(source);
  return CaretSnapshot.fromJson(
    jsonDecode(raw as String) as Map<String, dynamic>,
    surface: ReaderHibikiPage.debugCaretSurface?.call() ?? 'unknown',
  );
}

Future<PopupSnapshot> _waitForPopupResult(
  WidgetTester tester, {
  required String expectedTerm,
  required String expectedGloss,
}) async {
  PopupSnapshot? latest;
  for (int i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    final Future<dynamic> Function(String source)? topEval =
        ReaderHibikiPage.debugEvaluateTopPopup;
    if (topEval == null) continue;
    final raw = await topEval(_popupSnapshotJs);
    if (raw == null) continue;
    latest = PopupSnapshot.fromJson(
      jsonDecode(raw as String) as Map<String, dynamic>,
    );
    if (latest.webViewLoaded &&
        latest.containsTerm(expectedTerm) &&
        latest.containsGloss(expectedGloss)) {
      return latest;
    }
  }
  fail(
      'Popup did not load expected result for "$expectedTerm". latest=$latest');
}

const String _popupSnapshotJs = r'''
JSON.stringify((function() {
  var entries = Array.isArray(window.lookupEntries) ? window.lookupEntries : [];
  return {
    readyState: document.readyState,
    renderType: typeof window.renderPopup,
    caretType: typeof window.hoshiCaret,
    hasContainer: !!document.getElementById('entries-container'),
    glossaryCount: document.querySelectorAll('.glossary-content').length,
    body: document.body ? document.body.innerText : '',
    entries: entries.map(function(e) {
      return {
        expression: e.expression || '',
        reading: e.reading || '',
        matched: e.matched || '',
        glossaries: e.glossaries || []
      };
    })
  };
})())
''';

Future<void> _closePopupAndReturnToReader(WidgetTester tester) async {
  bool popupGone = false;
  for (int attempt = 0; attempt < 6; attempt++) {
    if (!popupGone) {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    }
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 150));
      if (!await _hasVisibleTopPopup()) {
        popupGone = true;
        final String surface =
            ReaderHibikiPage.debugCaretSurface?.call() ?? 'unknown';
        if (surface == 'reader') return;
      }
    }
    if (popupGone) break;
  }
  final String surface =
      ReaderHibikiPage.debugCaretSurface?.call() ?? 'unknown';
  fail('Escape did not close the visible dictionary popup and return focus '
      'to reader caret. popupGone=$popupGone surface=$surface');
}

Future<bool> _hasVisibleTopPopup() async {
  final Future<dynamic> Function(String source)? topEval =
      ReaderHibikiPage.debugEvaluateTopPopup;
  if (topEval == null) return false;
  final raw = await topEval('document.readyState');
  return raw != null;
}

class ReaderPageSnapshot {
  ReaderPageSnapshot({
    required this.ready,
    required this.scroll,
    required this.columnPitch,
    required this.maxScroll,
    required this.minScroll,
    required this.currentPage,
    required this.totalPages,
    required this.firstVisibleCharOffset,
    required this.progress,
    required this.vertical,
  });

  factory ReaderPageSnapshot.fromJson(Map<String, dynamic> json) {
    return ReaderPageSnapshot(
      ready: json['ready'] == true,
      scroll: (json['scroll'] as num?)?.toInt() ?? 0,
      columnPitch: (json['columnPitch'] as num?)?.toInt() ?? 0,
      maxScroll: (json['maxScroll'] as num?)?.toInt() ?? 0,
      minScroll: (json['minScroll'] as num?)?.toInt() ?? 0,
      currentPage: (json['currentPage'] as num?)?.toInt(),
      totalPages: (json['totalPages'] as num?)?.toInt(),
      firstVisibleCharOffset: (json['firstVisibleCharOffset'] as num?)?.toInt(),
      progress: json['progress'],
      vertical: json['vertical'] == true,
    );
  }

  final bool ready;
  final int scroll;
  final int columnPitch;
  final int maxScroll;
  final int minScroll;
  final int? currentPage;
  final int? totalPages;
  final int? firstVisibleCharOffset;
  final Object? progress;
  final bool vertical;

  bool isAfter(ReaderPageSnapshot other) {
    if (currentPage != null && other.currentPage != null) {
      return currentPage! > other.currentPage!;
    }
    return scroll > other.scroll + 1;
  }

  bool isBefore(ReaderPageSnapshot other) {
    if (currentPage != null && other.currentPage != null) {
      return currentPage! < other.currentPage!;
    }
    return scroll < other.scroll - 1;
  }

  bool sameLocation(ReaderPageSnapshot other) {
    return scroll == other.scroll &&
        currentPage == other.currentPage &&
        firstVisibleCharOffset == other.firstVisibleCharOffset;
  }

  @override
  String toString() {
    return 'ReaderPageSnapshot(page=$currentPage/$totalPages, scroll=$scroll, '
        'pitch=$columnPitch, max=$maxScroll, first=$firstVisibleCharOffset, '
        'vertical=$vertical)';
  }
}

class CaretSnapshot {
  CaretSnapshot({
    required this.surface,
    required this.active,
    required this.offset,
    required this.text,
    required this.character,
    required this.around,
  });

  factory CaretSnapshot.fromJson(
    Map<String, dynamic> json, {
    required String surface,
  }) {
    return CaretSnapshot(
      surface: surface,
      active: json['active'] == true,
      offset: (json['offset'] as num?)?.toInt() ?? -1,
      text: json['text']?.toString() ?? '',
      character: json['ch']?.toString() ?? '',
      around: json['around']?.toString() ?? '',
    );
  }

  final String surface;
  final bool active;
  final int offset;
  final String text;
  final String character;
  final String around;

  bool isOnTerm(String term) {
    if (term == _cat) return character == _cat;
    int start = text.indexOf(term);
    while (start >= 0) {
      if (offset >= start && offset < start + term.length) return true;
      start = text.indexOf(term, start + term.length);
    }
    return false;
  }

  @override
  String toString() {
    return 'CaretSnapshot(surface=$surface, active=$active, offset=$offset, '
        'char=$character, around="$around")';
  }
}

class PopupSnapshot {
  PopupSnapshot({
    required this.readyState,
    required this.renderType,
    required this.caretType,
    required this.hasContainer,
    required this.glossaryCount,
    required this.body,
    required this.entries,
  });

  factory PopupSnapshot.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawEntries = json['entries'] as List<dynamic>? ?? [];
    return PopupSnapshot(
      readyState: json['readyState']?.toString() ?? '',
      renderType: json['renderType']?.toString() ?? '',
      caretType: json['caretType']?.toString() ?? '',
      hasContainer: json['hasContainer'] == true,
      glossaryCount: (json['glossaryCount'] as num?)?.toInt() ?? 0,
      body: json['body']?.toString() ?? '',
      entries: rawEntries
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(growable: false),
    );
  }

  final String readyState;
  final String renderType;
  final String caretType;
  final bool hasContainer;
  final int glossaryCount;
  final String body;
  final List<Map<String, dynamic>> entries;

  bool get webViewLoaded =>
      hasContainer &&
      (readyState == 'interactive' || readyState == 'complete') &&
      caretType == 'object';

  String get payload => jsonEncode(entries);

  String get signature {
    final String expressions =
        entries.map((entry) => entry['expression']?.toString() ?? '').join('|');
    return '$expressions\n$payload\n$body';
  }

  bool containsTerm(String term) {
    return entries.any((entry) =>
            entry['expression'] == term ||
            entry['matched'] == term ||
            entry['reading'] == term) ||
        body.contains(term) ||
        payload.contains(term);
  }

  bool containsGloss(String gloss) =>
      body.contains(gloss) || payload.contains(gloss);

  @override
  String toString() {
    final expressions =
        entries.map((entry) => entry['expression']?.toString()).join(',');
    return 'PopupSnapshot(ready=$readyState, render=$renderType, '
        'caret=$caretType, entries=$expressions, glossaryCount=$glossaryCount)';
  }
}
