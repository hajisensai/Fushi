// Card field AI end to end in the real app (Windows off-screen runner): real DB,
// real note editor, real sheet / prompt editor / settings page, real
// AiChatClient talking to a fake OpenAI-compatible server inside the test
// process. Proves the request that goes over the wire is exactly the template
// the user sees (preview == request), the reply handling (structured / plain /
// fenced / malformed / empty), nothing is written before Append / Replace, the
// new-variant flows (blank copy + sample library), the request size limit, and
// the Card field AI settings page; then repeats the visual steps in the Apple
// design system, and finishes with a dark-mode pass (sheet result, editor
// preview, new-variant sheet, reply error) in both design systems. UX fixes
// asserted here: a failed re-run clears the previous suggestion, the suggestion
// keeps its inline formatting, the unused instruction box says so inside the
// field, duplicate variant names are numbered / warned, "New variant" is a
// labeled text button. Screenshots `NN-<what>-<m3e|apple>` (dark pass
// `D<n>-<what>-dark-<look>`); text evidence lines start with `[field-ai-itest]`.
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_field_ai_prompts_itest.dart
//
// Controls are driven focus-first (Tab to the control, Enter). Every press logs
// how it was reached (`tab` / `focus` / `callback`); `callback` is only used
// when the control could not be reached by focus and is reported as such.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';
import 'package:fushi/src/ai/ai_srs_field_samples.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_action.dart'
    show srsFieldAiOutputLanguage;
import 'package:fushi/src/pages/implementations/srs/srs_field_editors.dart'
    show SrsFieldEditor;
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_ai.dart'
    show buildAiDestination;
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiTextField;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiTextButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsNoteView;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[field-ai-itest]';

void _log(String line) => debugPrint('$_tag $line');

/// Soft assertion ledger: every check is logged PASS / FAIL, the test fails at
/// the end if any check failed (so one broken step doesn't hide the rest).
final List<String> _failures = <String>[];
String _scenario = '';

bool _check(bool ok, String what, [Object? detail]) {
  final String line = '$_scenario: $what${detail == null ? '' : ' -> $detail'}';
  _log('${ok ? 'PASS' : 'FAIL'} $line');
  if (!ok) _failures.add(line);
  return ok;
}

// ─────────────────────────── fake AI server ───────────────────────────

class _FakeAi {
  late HttpServer _server;
  final List<List<Map<String, Object?>>> requests =
      <List<Map<String, Object?>>>[];
  final List<String> replies = <String>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest req) => unawaited(_handle(req)));
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.method != 'POST' || !req.uri.path.endsWith('/chat/completions')) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final String body = await utf8.decodeStream(req);
    final Map<String, Object?> json =
        (jsonDecode(body) as Map<Object?, Object?>).cast<String, Object?>();
    final List<Map<String, Object?>> messages = <Map<String, Object?>>[
      for (final Object? m in json['messages']! as List<Object?>)
        (m! as Map<Object?, Object?>).cast<String, Object?>(),
    ];
    requests.add(messages);
    final String reply = replies.isEmpty ? '' : replies.removeAt(0);
    _log(
      'server: request #${requests.length} roles='
      '${messages.map((Map<String, Object?> m) => m['role']).join(',')} '
      'reply=${jsonEncode(reply)}',
    );
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode(<String, Object?>{
          'id': 'fake-${requests.length}',
          'object': 'chat.completion',
          'choices': <Object?>[
            <String, Object?>{
              'index': 0,
              'finish_reason': 'stop',
              'message': <String, Object?>{
                'role': 'assistant',
                'content': reply,
              },
            },
          ],
        }),
      );
    await req.response.close();
  }

  String system(int i) => requests[i][0]['content']! as String;
  String user(int i) => requests[i][1]['content']! as String;

  Future<void> close() => _server.close(force: true);
}

// ─────────────────────────── UI helpers ───────────────────────────

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<bool> _until(
  WidgetTester tester,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (cond()) return true;
    await tester.pump(const Duration(milliseconds: 100));
  }
  return cond();
}

Finder _key(String key, {bool skipOffstage = true}) =>
    find.byKey(ValueKey<String>(key), skipOffstage: skipOffstage);

bool _has(String key) => _key(key).evaluate().isNotEmpty;

final List<String> _shots = <String>[];

Future<void> _shot(WidgetTester tester, String name) async {
  // Bounded settle (entrance staggers ~0.6 s); never pumpAndSettle (spinners).
  await _pumpFor(tester, const Duration(milliseconds: 1200));
  final ObserveShot shot = await captureFlutterFrame(
    tester,
    name,
    settle: false,
  );
  _shots.add(shot.path);
  _log('shot $name saved=${shot.saved} nonBlank=${shot.nonBlank}');
}

String? _textOf(Widget w) => switch (w) {
  final Text t => t.data ?? t.textSpan?.toPlainText(),
  final SelectableText s => s.data ?? s.textSpan?.toPlainText(),
  final EditableText e => e.controller.text,
  _ => null,
};

/// Visible texts in [scope] (deduplicated in order), for log evidence.
List<String> _texts(Finder scope) {
  final List<String> out = <String>[];
  for (final Element e
      in find
          .descendant(
            of: scope,
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is Text || w is SelectableText || w is EditableText,
            ),
          )
          .evaluate()) {
    final String? s = _textOf(e.widget)?.trim();
    if (s == null || s.isEmpty) continue;
    final String one = s.length > 120
        ? '${s.substring(0, 120).replaceAll('\n', '⏎')}…'
        : s.replaceAll('\n', '⏎');
    if (!out.contains(one)) out.add(one);
  }
  return out;
}

void _logTexts(String what, Finder scope) =>
    _log('$what texts: ${jsonEncode(_texts(scope))}');

String _selectable(String key) => _textOf(_keyWidget(key)) ?? '<missing $key>';

Widget _keyWidget(String key) =>
    _key(key, skipOffstage: false).evaluate().first.widget;

/// Texts of the spans in the Text.rich behind [key] whose weight is >= w600.
List<String> _boldSpans(String key) {
  final Widget w = _keyWidget(key);
  final InlineSpan? root = w is Text ? w.textSpan : null;
  final List<String> out = <String>[];
  root?.visitChildren((InlineSpan span) {
    if (span is TextSpan &&
        (span.text ?? '').isNotEmpty &&
        (span.style?.fontWeight?.value ?? 400) >= 600) {
      out.add(span.text!);
    }
    return true;
  });
  return out;
}

/// Is the control behind [key] enabled (works across Fushi button / field types).
bool _enabled(String key) {
  final dynamic w = _keyWidget(key);
  try {
    final Object? e = w.enabled;
    if (e is bool) return e;
    if (e == null) return true;
  } on NoSuchMethodError {
    // fall through
  }
  try {
    return w.onPressed != null;
  } on NoSuchMethodError {
    // fall through
  }
  try {
    return w.onTap != null;
  } on NoSuchMethodError {
    return true;
  }
}

/// How each control was reached the first time: label -> method.
final Map<String, String> _pressMethods = <String, String>{};

/// Press the control behind [f]: Tab to it and Enter; if Tab can't reach it,
/// move focus into it and Enter; only then call its callback (logged). Tab
/// reachability is proven once per control label; later presses of the same
/// control move focus to it directly (then Enter) to keep the run short.
Future<String> _press(
  WidgetTester tester,
  FocusDriver d,
  Finder f,
  String label, {
  int maxTabs = 60,
  bool Function()? done,
}) async {
  if (f.evaluate().isEmpty) {
    _check(false, 'control present: $label');
    return 'missing';
  }
  Future<bool> fired() async {
    if (done == null) {
      await _pumpFor(tester, const Duration(milliseconds: 300));
      return true;
    }
    return _until(tester, done, timeout: const Duration(seconds: 2));
  }

  final String? known = _pressMethods[label];
  String method = 'callback';
  if (known == null && await d.focusWidget(f, maxSteps: maxTabs)) {
    await d.activate();
    if (await fired()) method = 'tab';
  }
  if (method == 'callback' && f.evaluate().isNotEmpty) {
    final FocusNode? node = _focusNodeIn(f);
    if (node != null) {
      node.requestFocus();
      await tester.pump(const Duration(milliseconds: 200));
      await d.activate();
      if (await fired()) method = known == 'tab' ? 'tab' : 'focus';
    }
  }
  if (method == 'callback' &&
      known == 'tab' &&
      f.evaluate().isNotEmpty &&
      await d.focusWidget(f, maxSteps: maxTabs)) {
    await d.activate();
    if (await fired()) method = 'tab';
  }
  if (method == 'callback' && f.evaluate().isNotEmpty) {
    final dynamic w = tester.widget(f.first);
    bool called = false;
    for (final String name in <String>['onPressed', 'onTap']) {
      try {
        final Object? cb = name == 'onPressed' ? w.onPressed : w.onTap;
        if (cb is Function) {
          final Object? r = Function.apply(cb, const <Object?>[]);
          if (r is Future) unawaited(r);
          called = true;
          break;
        }
      } on NoSuchMethodError {
        continue;
      }
    }
    if (!called) {
      _check(false, 'could not activate $label by focus or callback');
      method = 'failed';
    }
    await fired();
  }
  _pressMethods.putIfAbsent(label, () => method);
  _log('press $label via $method');
  return method;
}

/// First focusable node owned by [f]'s subtree.
FocusNode? _focusNodeIn(Finder f) {
  final Element root = f.evaluate().first;
  FocusNode? found;
  void visit(Element e) {
    if (found != null) return;
    final Widget w = e.widget;
    if (w is Focus && w.focusNode != null) {
      final FocusNode n = w.focusNode!;
      if (n.canRequestFocus && !n.skipTraversal && n is! FocusScopeNode) {
        found = n;
        return;
      }
    }
    e.visitChildren(visit);
  }

  visit(root);
  if (found != null) return found;
  // The control's own Focus may create its node internally: ask from inside.
  Element? leaf;
  root.visitChildren((Element c) => leaf ??= c);
  final FocusNode? n = leaf == null ? null : Focus.maybeOf(leaf!);
  return n is FocusScopeNode ? null : n;
}

/// Select [value] in the segmented control inside [scope] whose selection is a
/// `Set<T>`; focus-first (segment label + Enter, then arrows), callback last.
Future<String> _selectSegment<T extends Object>(
  WidgetTester tester,
  FocusDriver d,
  Finder scope,
  T value,
  String label,
  String segmentText,
  List<T> order,
) async {
  final Finder seg = find
      .descendant(
        of: scope,
        matching: find.byWidgetPredicate((Widget w) {
          if (!w.runtimeType.toString().contains('Segmented')) return false;
          try {
            return (w as dynamic).selected is Set<T>;
          } on NoSuchMethodError {
            return false;
          }
        }),
      )
      .first;
  Set<T> selected() => (tester.widget(seg) as dynamic).selected as Set<T>;
  if (selected().contains(value)) return 'already';
  String method = 'callback';
  final Finder labelFinder = find.descendant(
    of: seg,
    matching: find.text(segmentText),
  );
  if (labelFinder.evaluate().isNotEmpty &&
      await d.focusWidget(labelFinder, maxSteps: 40)) {
    await d.activate();
    await _pumpFor(tester, const Duration(milliseconds: 300));
    if (selected().contains(value)) {
      method = 'tab';
    } else {
      final T current = selected().first;
      await d.adjust(steps: order.indexOf(value) - order.indexOf(current));
      await _pumpFor(tester, const Duration(milliseconds: 300));
      if (selected().contains(value)) method = 'tab+arrows';
    }
  }
  if (method == 'callback') {
    ((tester.widget(seg) as dynamic).onSelectionChanged as Function)(<T>{
      value,
    });
    await _pumpFor(tester, const Duration(milliseconds: 300));
  }
  _pressMethods.putIfAbsent(label, () => method);
  _log('segment $label -> $value via $method');
  return method;
}

/// Dismiss the top sheet / route: Escape first, Navigator pop if that didn't.
Future<void> _dismiss(
  WidgetTester tester,
  FocusDriver d,
  String key,
  String label,
) async {
  if (!_has(key)) return;
  await d.back();
  await _pumpFor(tester, const Duration(milliseconds: 600));
  String method = 'escape';
  if (_has(key)) {
    method = 'navigator';
    Navigator.of(_key(key).evaluate().first).pop();
    await _pumpFor(tester, const Duration(milliseconds: 600));
  }
  _pressMethods.putIfAbsent('dismiss $label', () => method);
  _log('dismiss $label via $method (gone=${!_has(key)})');
}

void _ensureVisible(String key) {
  final Finder f = _key(key, skipOffstage: false);
  if (f.evaluate().isEmpty) return;
  unawaited(
    Scrollable.ensureVisible(
      f.evaluate().first,
      alignment: 0.05,
      duration: Duration.zero,
    ),
  );
}

// ─────────────────────────── fixtures ───────────────────────────

const String _sentenceA = 'それに<b>気づいた</b>時 完全に嫌いになった';
const String _sentenceB = 'うっかりかあ';
const String _translateReply =
    '{"value":"When I <b>noticed</b> that, I came to hate it completely.",'
    '"explanation":"Subject and object are implied (I / it)."}';
const String _translateValue =
    'When I <b>noticed</b> that, I came to hate it completely.';

Map<String, String> _noteA() => <String, String>{
  'Term': '気づく',
  'TermReading': 'きづく',
  'MainDefinition': 'to notice; to realize',
  'Glossary':
      '<ol><li>to notice; to recognize; to become aware of</li>'
      '<li>to come to oneself; to regain consciousness</li></ol>',
  'Sentence': _sentenceA,
};

Map<String, String> _noteB() => <String, String>{
  'Term': 'うっかり',
  'TermReading': 'うっかり',
  'MainDefinition': 'carelessly; inadvertently',
  'Sentence': _sentenceB,
};

Map<String, String> _noteC() => <String, String>{
  'Term': '長い',
  'TermReading': 'ながい',
  'MainDefinition': 'long',
  'Glossary': '語義の説明文です。' * 3400, // 30 600 chars
  'Sentence': '<b>長い</b>話だった',
};

class _Ctx {
  _Ctx(this.tester, this.appModel, this.store, this.d, this.ai);

  final WidgetTester tester;
  final AppModel appModel;
  final SrsDbStore store;
  final FocusDriver d;
  final _FakeAi ai;
  late String noteA;
  late String noteB;
  late String noteC;
  late Map<String, String> fieldIdByName;
  String look = 'm3e';

  NavigatorState get nav => appModel.navigatorKey.currentState!;

  String get lang => srsFieldAiOutputLanguage(appModel);

  AiSrsFieldActions get actions => appModel.prefsRepo.aiFieldActions;

  Future<String> createNote(Map<String, String> values) => store.createNote(
    noteTypeId: store.fushiCardNoteTypeId,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    fieldsById: <String, String>{
      for (final MapEntry<String, String> e in values.entries)
        srsFushiCardFieldId(store.profileUid, e.key): e.value,
    },
  );

  Future<Map<String, String>> noteFields(String id) async {
    final SrsNoteView? n = await store.note(id);
    return <String, String>{
      for (final MapEntry<String, String> e in fieldIdByName.entries)
        e.key: n?.fields[e.value] ?? '',
    };
  }

  /// Field editor model value (what Append / Replace write before Save).
  String fieldModel(String name) => tester
      .widget<SrsFieldEditor>(_key('srs-field-$name', skipOffstage: false))
      .model
      .value;

  Map<String, String> allFieldModels() => <String, String>{
    for (final String name in fieldIdByName.keys)
      if (_key('srs-field-$name', skipOffstage: false).evaluate().isNotEmpty)
        name: fieldModel(name),
  };

  Future<void> popToRoot() async {
    nav.popUntil((Route<dynamic> r) => r.isFirst);
    await _pumpFor(tester, const Duration(milliseconds: 800));
  }

  Future<void> openEditor(String noteId) async {
    await popToRoot();
    unawaited(
      nav.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => SrsNoteEditorPage(noteId: noteId),
        ),
      ),
    );
    final bool ok = await _until(
      tester,
      () => _key(
        'srs-field-SentenceTranslation',
        skipOffstage: false,
      ).evaluate().isNotEmpty,
    );
    _check(ok, 'note editor loaded ($noteId)');
    await _pumpFor(tester, const Duration(milliseconds: 800));
    if (!_has('srs-field-ai-SentenceTranslation') &&
        _has('srs-note-more-fields')) {
      await _press(
        tester,
        d,
        _key('srs-note-more-fields'),
        'note editor › more fields',
        done: () => _has('srs-field-ai-SentenceTranslation'),
      );
      await _pumpFor(tester, const Duration(milliseconds: 600));
    }
  }

  Future<void> openSheet() async {
    _ensureVisible('srs-field-ai-SentenceTranslation');
    await _pumpFor(tester, const Duration(milliseconds: 300));
    await _press(
      tester,
      d,
      _key('srs-field-ai-SentenceTranslation'),
      'note editor › field AI button',
      maxTabs: 120,
      done: () => _has('srs-field-ai-sheet'),
    );
    _check(
      await _until(tester, () => _has('srs-field-ai-sheet')),
      'field AI sheet opened',
    );
    await _pumpFor(tester, const Duration(milliseconds: 700));
  }

  Future<void> openPromptEditorFromSheet() async {
    await _press(
      tester,
      d,
      _key('srs-field-ai-edit-prompt'),
      'sheet › Edit prompt',
      done: () => _has('srs-field-ai-prompt-editor'),
    );
    _check(
      await _until(tester, () => _has('srs-field-ai-prompt-editor')),
      'prompt editor opened',
    );
    await _pumpFor(tester, const Duration(milliseconds: 800));
  }

  Future<void> closePromptEditor() async {
    await _dismiss(tester, d, 'srs-field-ai-prompt-editor', 'prompt editor');
    await _until(tester, () => !_has('srs-field-ai-prompt-editor'));
  }

  /// Press Run and wait for a suggestion / reply error / failure.
  Future<void> run(String reply, {bool expectRequest = true}) async {
    final int before = ai.requests.length;
    ai.replies
      ..clear()
      ..add(reply);
    await _press(
      tester,
      d,
      _key('srs-field-ai-run'),
      'sheet › Run',
      done: () => ai.requests.length > before || _busy(),
    );
    final bool got = await _until(
      tester,
      () =>
          ai.requests.length > before &&
          !_busy() &&
          (_has('srs-field-ai-result') ||
              _has('srs-field-ai-reply-error') ||
              _has('srs-field-ai-error')),
      timeout: const Duration(seconds: 25),
    );
    if (expectRequest) _check(got, 'request answered');
    await _pumpFor(tester, const Duration(milliseconds: 500));
  }

  bool _busy() => find
      .descendant(
        of: _key('srs-field-ai-sheet'),
        matching: find.byType(FushiCircularProgressIndicator),
      )
      .evaluate()
      .isNotEmpty;

  /// The note JSON a user message carries, given the [template] prefix/suffix.
  Map<String, Object?>? splitNoteJson(String user, String expandedTemplate) {
    final int at = expandedTemplate.indexOf('{{note}}');
    if (at < 0) return null;
    final String prefix = expandedTemplate.substring(0, at);
    final String suffix = expandedTemplate.substring(at + '{{note}}'.length);
    if (!user.startsWith(prefix) || !user.endsWith(suffix)) {
      _log(
        'template frame mismatch: prefixOk=${user.startsWith(prefix)} '
        'suffixOk=${user.endsWith(suffix)}',
      );
      return null;
    }
    final String json = user.substring(
      prefix.length,
      user.length - suffix.length,
    );
    return (jsonDecode(json) as Map<Object?, Object?>).cast<String, Object?>();
  }

  String expandFixed(String template, {String instruction = '(none)'}) =>
      template
          .replaceAll('{{output_language}}', lang)
          .replaceAll('{{target_field}}', 'SentenceTranslation')
          .replaceAll('{{instruction}}', instruction);

  String guidanceFor(String guidance) =>
      guidance.replaceAll('{{output_language}}', lang).trim();

  String systemFor(String guidance, AiSrsFieldResponseMode mode) {
    final String g = guidanceFor(guidance);
    final String rules = aiSrsFieldAppRules(mode, outputLanguage: lang);
    return g.isEmpty ? rules : '$g\n\n$rules';
  }
}

String _contentOf(Map<String, Object?> note, String field) {
  for (final Object? f in note['fields']! as List<Object?>) {
    final Map<Object?, Object?> m = f! as Map<Object?, Object?>;
    if (m['name'] == field) return '${m['content']}';
  }
  return '<absent>';
}

// ─────────────────────────── scenarios ───────────────────────────

Future<void> _guard(_Ctx c, String name, Future<void> Function() body) async {
  _scenario = name;
  _log('=== $name (${c.look}) ===');
  try {
    await body();
  } catch (e, st) {
    _check(false, 'threw', e);
    _log('stack: ${st.toString().split('\n').take(8).join(' | ')}');
    try {
      await captureFlutterFrame(c.tester, 'zz-error-$name-${c.look}');
    } catch (_) {}
    await c.popToRoot();
  }
}

Future<void> _s1Sheet(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteA);
  await _shot(tester, '00-note-editor-${c.look}');
  await c.openSheet();
  await _shot(tester, '01-sheet-translate-${c.look}');
  final Finder sheet = _key('srs-field-ai-sheet');
  _logTexts('sheet', sheet);
  _check(_has('srs-field-ai-edit-prompt'), 'Edit prompt button');
  _check(_has('srs-field-ai-new-variant'), 'New variant button');
  // Fix 10: labeled text button in the same style as Edit prompt, >= 48 dp.
  _check(
    _keyWidget('srs-field-ai-new-variant') is FushiTextButton &&
        _keyWidget('srs-field-ai-edit-prompt') is FushiTextButton,
    'New variant / Edit prompt are both text buttons',
  );
  _check(
    find
        .descendant(
          of: _key('srs-field-ai-new-variant'),
          matching: find.text(t.srs_field_ai_prompt_new_variant),
        )
        .evaluate()
        .isNotEmpty,
    'New variant button is labeled',
  );
  final Size nvSize = tester.getSize(_key('srs-field-ai-new-variant'));
  final Size epSize = tester.getSize(_key('srs-field-ai-edit-prompt'));
  // The app pads touch targets to 48 dp on touch platforms (tap target size
  // `padded`); desktop precise pointers keep the compact size on purpose
  // (FushiTouchTargetPadding / HBK-AUDIT-020). Widget tests cover the 48 dp
  // case on Android; here the two buttons must at least match.
  final bool padded =
      Theme.of(
        _key('srs-field-ai-new-variant').evaluate().first,
      ).materialTapTargetSize ==
      MaterialTapTargetSize.padded;
  _check(
    nvSize.height == epSize.height && (!padded || nvSize.height >= 48),
    'New variant as tall as Edit prompt (>= 48 dp on touch platforms)',
    '$nvSize vs $epSize padded=$padded',
  );
  _check(
    find
        .descendant(
          of: _key('ai-saved-prompts-srs_field'),
          matching: find.byWidgetPredicate((Widget w) {
            // Material Tooltip (M3E) or FushiTooltip (Apple).
            if (!w.runtimeType.toString().contains('Tooltip')) return false;
            try {
              return (w as dynamic).message == t.ai_prompt_library_title;
            } on NoSuchMethodError {
              return false;
            }
          }),
        )
        .evaluate()
        .isNotEmpty,
    'presets bookmark has a tooltip',
  );
  _check(_has('srs-field-ai-instruction'), 'instruction box');
  _check(_enabled('srs-field-ai-instruction'), 'instruction box enabled');
  _check(_has('srs-field-ai-run') && _enabled('srs-field-ai-run'), 'Run on');
  _check(
    find
        .descendant(
          of: sheet,
          matching: find.text(t.srs_note_field_ai_translate),
        )
        .evaluate()
        .isNotEmpty,
    'task selector shows Translate',
  );
  if (c.look != 'm3e') return;

  const Map<AiSrsFieldTask, Set<String>> expected =
      <AiSrsFieldTask, Set<String>>{
        AiSrsFieldTask.define: <String>{
          'simpler',
          'shorter',
          'one_sense',
          'add_example',
        },
        AiSrsFieldTask.translate: <String>{
          'simpler',
          'casual',
          'formal',
          'target_nuance',
        },
        AiSrsFieldTask.rewrite: <String>{'simpler', 'shorter', 'format_only'},
        AiSrsFieldTask.custom: <String>{'simpler', 'shorter'},
      };
  final Map<AiSrsFieldTask, String> labels = <AiSrsFieldTask, String>{
    AiSrsFieldTask.define: t.srs_note_field_ai_define,
    AiSrsFieldTask.translate: t.srs_note_field_ai_translate,
    AiSrsFieldTask.rewrite: t.srs_note_field_ai_rewrite,
    AiSrsFieldTask.custom: t.srs_note_field_ai_custom,
  };
  const String prefix = 'ai-saved-prompt-builtin:srs_field:';
  for (final AiSrsFieldTask task in <AiSrsFieldTask>[
    AiSrsFieldTask.define,
    AiSrsFieldTask.translate,
    AiSrsFieldTask.rewrite,
    AiSrsFieldTask.custom,
  ]) {
    await _selectSegment<AiSrsFieldTask>(
      tester,
      c.d,
      sheet,
      task,
      'sheet › task selector',
      labels[task]!,
      AiSrsFieldTask.values,
    );
    await _press(
      tester,
      c.d,
      _key('ai-saved-prompts-srs_field'),
      'sheet › presets button',
      done: () => _has('ai-saved-prompt-sheet'),
    );
    await _until(tester, () => _has('ai-saved-prompt-sheet'));
    await _pumpFor(tester, const Duration(milliseconds: 600));
    final Set<String> shown = <String>{
      for (final Element e
          in find
              .byWidgetPredicate(
                (Widget w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(prefix),
              )
              .evaluate())
        (e.widget.key! as ValueKey<String>).value.substring(prefix.length),
    };
    _check(
      shown.length == expected[task]!.length &&
          shown.containsAll(expected[task]!),
      'presets for ${task.name}',
      shown,
    );
    if (task == AiSrsFieldTask.translate || task == AiSrsFieldTask.define) {
      await _shot(tester, '02-presets-${task.name}-${c.look}');
    }
    await _dismiss(tester, c.d, 'ai-saved-prompt-sheet', 'presets sheet');
  }
  await _selectSegment<AiSrsFieldTask>(
    tester,
    c.d,
    sheet,
    AiSrsFieldTask.translate,
    'sheet › task selector',
    labels[AiSrsFieldTask.translate]!,
    AiSrsFieldTask.values,
  );
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
}

Future<void> _s2RunTranslate(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteA);
  final Map<String, String> before = c.allFieldModels();
  await c.openSheet();
  final int n0 = c.ai.requests.length;
  await c.run(_translateReply);
  _check(c.ai.requests.length == n0 + 1, 'exactly one request');
  final int i = c.ai.requests.length - 1;
  _check(c.ai.requests[i].length == 2, 'two messages');
  _check(
    c.ai.requests[i][0]['role'] == 'system' &&
        c.ai.requests[i][1]['role'] == 'user',
    'roles system,user',
  );
  final String wantSystem = c.systemFor(
    kAiSrsFieldGuidance,
    AiSrsFieldResponseMode.structured,
  );
  _check(c.ai.system(i) == wantSystem, 'system == guidance + app rules');
  final String user = c.ai.user(i);
  _log('request user message:\n$user');
  _log('request system message:\n${c.ai.system(i)}');
  final Map<String, Object?>? note = c.splitNoteJson(
    user,
    c.expandFixed(kAiSrsFieldTranslateTemplate),
  );
  _check(note != null, 'user message == translate template + {{note}} only');
  if (note != null) {
    _check(note['note_type'] == 'Fushi Card', 'note_type', note['note_type']);
    _check(
      note['target_field'] == 'SentenceTranslation',
      'target_field',
      note['target_field'],
    );
    _check(
      _contentOf(note, 'Sentence') == _sentenceA,
      'Sentence reaches request intact',
      _contentOf(note, 'Sentence'),
    );
    _check(_contentOf(note, 'Term') == '気づく', 'Term in note JSON');
    _check(
      _contentOf(note, 'SentenceTranslation') == '',
      'empty target listed with ""',
    );
    _check(
      (note['empty_fields'] as List<Object?>? ?? const <Object?>[]).contains(
        'Hint',
      ),
      'empty_fields lists Hint',
    );
  }
  _check(user.contains('それに<b>気づいた</b>時'), 'raw sentence with <b> in user');
  _check(
    _selectable('srs-field-ai-result-text') ==
        'When I noticed that, I came to hate it completely.',
    'suggestion rendered',
    _selectable('srs-field-ai-result-text'),
  );
  _check(
    find.text('Subject and object are implied (I / it).').evaluate().isNotEmpty,
    'explanation rendered',
  );
  // Fix 2: the preview keeps the inline formatting (<b>noticed</b> is bold).
  _check(
    _boldSpans('srs-field-ai-result-text').join('|') == 'noticed',
    'suggestion preview renders <b>noticed</b> bold',
    _boldSpans('srs-field-ai-result-text'),
  );
  _check(!_has('srs-field-ai-append'), 'no Append while field is empty');
  _check(
    c.fieldModel('SentenceTranslation') == '',
    'nothing written before Replace',
  );
  await _shot(tester, '03-translate-result-${c.look}');
  _logTexts('result sheet', _key('srs-field-ai-sheet'));
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-replace'),
    'sheet › Replace',
    done: () => !_has('srs-field-ai-sheet'),
  );
  await _until(tester, () => !_has('srs-field-ai-sheet'));
  await _pumpFor(tester, const Duration(milliseconds: 500));
  final Map<String, String> afterReplace = c.allFieldModels();
  _check(
    afterReplace['SentenceTranslation'] == _translateValue,
    'Replace wrote the field',
    afterReplace['SentenceTranslation'],
  );
  _check(
    <String>[
      for (final String k in before.keys)
        if (k != 'SentenceTranslation' && before[k] != afterReplace[k]) k,
    ].isEmpty,
    'Replace touched only SentenceTranslation',
  );

  await c.openSheet();
  await c.run(_translateReply);
  _check(_has('srs-field-ai-append'), 'Append offered when field has content');
  await _shot(tester, '04-translate-append-offer-${c.look}');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-append'),
    'sheet › Append',
    done: () => !_has('srs-field-ai-sheet'),
  );
  await _until(tester, () => !_has('srs-field-ai-sheet'));
  await _pumpFor(tester, const Duration(milliseconds: 500));
  const String appended = '$_translateValue<br>$_translateValue';
  _check(
    c.fieldModel('SentenceTranslation') == appended,
    'Append appended with <br>',
    c.fieldModel('SentenceTranslation'),
  );

  final Map<String, String> dbBefore = await c.noteFields(c.noteA);
  await _press(
    tester,
    c.d,
    _key('srs_note_save'),
    'note editor › Save',
    maxTabs: 120,
    done: () => !_key('srs_note_save').evaluate().isNotEmpty,
  );
  await _until(tester, () => find.byType(SrsNoteEditorPage).evaluate().isEmpty);
  final Map<String, String> dbAfter = await c.noteFields(c.noteA);
  _check(
    dbAfter['SentenceTranslation'] == appended,
    'DB SentenceTranslation after save',
    dbAfter['SentenceTranslation'],
  );
  _check(
    <String>[
      for (final String k in dbBefore.keys)
        if (k != 'SentenceTranslation' && dbBefore[k] != dbAfter[k]) k,
    ].isEmpty,
    'DB: no other field changed',
  );
}

Future<void> _s3PreviewEqualsRequest(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteA);
  await c.openSheet();
  await c.openPromptEditorFromSheet();
  await _shot(tester, '05-prompt-editor-top-${c.look}');
  _logTexts('prompt editor', _key('srs-field-ai-prompt-editor'));
  _check(
    tester.getSize(_key('srs-field-ai-prompt-editor')).width <= 900,
    'editor content capped at 900 px on the wide window',
    tester.getSize(_key('srs-field-ai-prompt-editor')).width,
  );
  final String pUser = _selectable('srs-field-ai-prompt-preview-user');
  final String pGuidance = _has('srs-field-ai-prompt-preview-guidance')
      ? _selectable('srs-field-ai-prompt-preview-guidance')
      : '';
  final String pRules = _selectable('srs-field-ai-prompt-preview-rules');
  final String pSystem = pGuidance.isEmpty ? pRules : '$pGuidance\n\n$pRules';
  _ensureVisible('srs-field-ai-prompt-preview-user-card');
  await _shot(tester, '06-prompt-editor-preview-${c.look}');
  _ensureVisible('srs-field-ai-prompt-preview-rules-card');
  await _shot(tester, '07-prompt-editor-rules-${c.look}');
  await c.closePromptEditor();
  await c.run(_translateReply);
  final int i = c.ai.requests.length - 1;
  _check(c.ai.user(i) == pUser, 'preview user == sent user (byte equal)');
  _check(c.ai.system(i) == pSystem, 'preview system == sent system');
  if (c.ai.user(i) != pUser) {
    _log('preview user:\n$pUser\n--- sent user:\n${c.ai.user(i)}');
  }
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
  _check(
    c.fieldModel('SentenceTranslation') ==
        '$_translateValue<br>$_translateValue',
    'dismissed sheet wrote nothing',
  );
}

const String _editedTemplate = 'Translate {{Sentence}} into English.';
const String _editedGuidance =
    'Be concise. Target language: {{output_language}}.';

Future<void> _s4Editor(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteA);
  await c.openSheet();
  await c.openPromptEditorFromSheet();
  await tester.enterText(_key('srs-field-ai-prompt-text'), _editedTemplate);
  await _pumpFor(tester, const Duration(milliseconds: 500));
  const String filled = 'Translate $_sentenceA into English.';
  _check(
    _selectable('srs-field-ai-prompt-preview-user') == filled,
    'preview user == edited template filled in',
    _selectable('srs-field-ai-prompt-preview-user'),
  );
  _check(
    !_has('srs-field-ai-prompt-preview-instruction'),
    'no preview-instruction box without {{instruction}}',
  );
  await tester.enterText(
    _key('srs-field-ai-prompt-text'),
    '$_editedTemplate {{Nope}}',
  );
  await _pumpFor(tester, const Duration(milliseconds: 500));
  _check(_has('srs-field-ai-notice-unknown'), 'unknown placeholder warning');
  _check(
    _selectable('srs-field-ai-notice-unknown').contains('{{Nope}}'),
    'warning names {{Nope}}',
    _selectable('srs-field-ai-notice-unknown'),
  );
  _check(
    _selectable('srs-field-ai-prompt-preview-user').endsWith('{{Nope}}'),
    'unknown placeholder left literal in preview',
  );
  _ensureVisible('srs-field-ai-prompt-text');
  await _shot(tester, '08-prompt-editor-unknown-${c.look}');

  // Placeholder picker: search + insert with a leading space.
  await tester.enterText(_key('srs-field-ai-prompt-text'), _editedTemplate);
  await _pumpFor(tester, const Duration(milliseconds: 300));
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-prompt-insert'),
    'editor › Insert placeholder',
    done: () => _has('srs-field-ai-placeholder-sheet'),
  );
  await _until(tester, () => _has('srs-field-ai-placeholder-sheet'));
  await _shot(tester, '09-placeholder-picker-${c.look}');
  _logTexts('placeholder picker', _key('srs-field-ai-placeholder-sheet'));
  await tester.enterText(_key('srs-field-ai-placeholder-search'), 'reading');
  await _pumpFor(tester, const Duration(milliseconds: 600));
  final List<String> filtered = <String>[
    for (final Element e
        in find
            .byWidgetPredicate(
              (Widget w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith(
                    'srs-field-ai-placeholder-',
                  ) &&
                  (w.key! as ValueKey<String>).value !=
                      'srs-field-ai-placeholder-sheet' &&
                  (w.key! as ValueKey<String>).value !=
                      'srs-field-ai-placeholder-search',
            )
            .evaluate())
      (e.widget.key! as ValueKey<String>).value,
  ];
  _log('placeholder search "reading" -> $filtered');
  _check(
    filtered.contains('srs-field-ai-placeholder-field-TermReading') &&
        !filtered.contains('srs-field-ai-placeholder-note'),
    'search filters the list',
    filtered,
  );
  await _shot(tester, '10-placeholder-search-${c.look}');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-placeholder-field-TermReading'),
    'placeholder picker › entry',
    done: () => !_has('srs-field-ai-placeholder-sheet'),
  );
  await _until(tester, () => !_has('srs-field-ai-placeholder-sheet'));
  final String afterInsert =
      (tester.widget(
                find.descendant(
                  of: _key('srs-field-ai-prompt-text'),
                  matching: find.byType(EditableText),
                ),
              )
              as EditableText)
          .controller
          .text;
  _check(
    afterInsert == '$_editedTemplate {{TermReading}}',
    'inserted at cursor with leading space',
    afterInsert,
  );
  await tester.enterText(_key('srs-field-ai-prompt-text'), _editedTemplate);
  await _pumpFor(tester, const Duration(milliseconds: 300));

  // Response format switch.
  final Finder editor = _key('srs-field-ai-prompt-editor');
  await _selectSegment<AiSrsFieldResponseMode>(
    tester,
    c.d,
    editor,
    AiSrsFieldResponseMode.plain,
    'editor › response format',
    t.srs_field_ai_prompt_response_plain,
    AiSrsFieldResponseMode.values,
  );
  _check(
    _selectable(
      'srs-field-ai-prompt-preview-rules',
    ).contains('Reply with only the new content of the field'),
    'plain mode -> plain app rule in preview',
  );
  await _selectSegment<AiSrsFieldResponseMode>(
    tester,
    c.d,
    editor,
    AiSrsFieldResponseMode.structured,
    'editor › response format',
    t.srs_field_ai_prompt_response_structured,
    AiSrsFieldResponseMode.values,
  );
  _check(
    _selectable(
      'srs-field-ai-prompt-preview-rules',
    ).contains('{"value": "<new field content>"'),
    'structured mode -> JSON app rule in preview',
  );

  // Advanced › AI guidance.
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-prompt-advanced'),
    'editor › Advanced',
    done: () => _has('srs-field-ai-prompt-guidance'),
  );
  await _until(tester, () => _has('srs-field-ai-prompt-guidance'));
  await tester.enterText(_key('srs-field-ai-prompt-guidance'), _editedGuidance);
  await _pumpFor(tester, const Duration(milliseconds: 500));
  _check(
    _selectable('srs-field-ai-prompt-preview-guidance') ==
        c.guidanceFor(_editedGuidance),
    'preview guidance == edited guidance filled in',
    _selectable('srs-field-ai-prompt-preview-guidance'),
  );
  _ensureVisible('srs-field-ai-prompt-guidance');
  await _shot(tester, '11-prompt-editor-advanced-${c.look}');
  _check(_enabled('srs-field-ai-prompt-save'), 'Save enabled when dirty');
  _check(!_enabled('srs-field-ai-prompt-reset'), 'Reset off before saving');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-prompt-save'),
    'editor › Save',
    done: () => c.actions.isOverridden('task.translate'),
  );
  await _until(tester, () => c.actions.isOverridden('task.translate'));
  final AiSrsFieldActionPrompt? saved = c.actions.promptOf('task.translate');
  _check(
    saved?.template == _editedTemplate &&
        saved?.guidance == _editedGuidance &&
        saved?.mode == AiSrsFieldResponseMode.structured,
    'saved override (template, guidance, mode)',
    saved?.template,
  );
  _check(_enabled('srs-field-ai-prompt-reset'), 'Reset on after saving');
  await c.closePromptEditor();
  await c.openPromptEditorFromSheet();
  final String reopened =
      (tester.widget(
                find.descendant(
                  of: _key('srs-field-ai-prompt-text'),
                  matching: find.byType(EditableText),
                ),
              )
              as EditableText)
          .controller
          .text;
  _check(reopened == _editedTemplate, 'reopen shows saved template', reopened);
  await _shot(tester, '12-prompt-editor-reopened-${c.look}');
  await c.closePromptEditor();
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
}

Future<void> _s7And8NoInstruction(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteA);
  final String fieldBefore = c.fieldModel('SentenceTranslation');
  await c.openSheet();
  _check(!_enabled('srs-field-ai-instruction'), 'instruction box disabled');
  _check(_has('srs-field-ai-instruction-unused'), 'hint "doesn\'t use"');
  // Fix 3: the disabled box itself says the prompt doesn't use it.
  final FushiTextField box = tester.widget<FushiTextField>(
    _key('srs-field-ai-instruction'),
  );
  _check(
    box.hintText == t.srs_note_field_ai_instruction_unused_hint &&
        (box.controller?.text ?? '').isEmpty &&
        box.prefixIcon != null,
    'disabled instruction box reads "not used by this prompt"',
    box.hintText,
  );
  _check(!_has('ai-saved-prompts-srs_field'), 'presets hidden');
  _check(_enabled('srs-field-ai-run'), 'Run on without instruction');
  await _shot(tester, '13-sheet-no-instruction-${c.look}');
  const String malformed = 'Sure! Here it is: {value: When I noticed that';
  await c.run(malformed);
  final int i = c.ai.requests.length - 1;
  _check(
    c.ai.user(i) == 'Translate $_sentenceA into English.',
    'sent user == edited template, nothing else',
    c.ai.user(i),
  );
  _check(
    c.ai.system(i) ==
        c.systemFor(_editedGuidance, AiSrsFieldResponseMode.structured),
    'sent system == edited guidance + structured rules',
  );
  _check(_has('srs-field-ai-reply-error'), 'malformed -> reply error card');
  _check(
    _selectable('srs-field-ai-reply-error-text') ==
        t.srs_note_field_ai_reply_unreadable,
    'error message is "couldn\'t read reply"',
    _selectable('srs-field-ai-reply-error-text'),
  );
  await _shot(tester, '14-malformed-reply-${c.look}');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-show-reply'),
    'sheet › Show reply',
    done: () => _has('srs-field-ai-raw-reply'),
  );
  await _until(tester, () => _has('srs-field-ai-raw-reply'));
  _check(
    _selectable('srs-field-ai-raw-reply') == malformed,
    'raw reply shown verbatim',
  );
  await _shot(tester, '15-malformed-show-reply-${c.look}');
  _check(
    c.fieldModel('SentenceTranslation') == fieldBefore,
    'nothing written on malformed',
  );
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-use-as-text'),
    'sheet › Use reply as text',
    done: () => _has('srs-field-ai-result'),
  );
  await _until(tester, () => _has('srs-field-ai-result'));
  _check(
    _selectable('srs-field-ai-result-text') == malformed,
    'use as text -> suggestion',
    _selectable('srs-field-ai-result-text'),
  );
  _check(
    c.fieldModel('SentenceTranslation') == fieldBefore,
    'still nothing written before Append / Replace',
  );
  await _shot(tester, '16-use-as-text-${c.look}');

  // Empty (after sanitizing) plain-text reply path is covered in S6; an empty
  // structured value:
  await c.run('{"value":"   ","explanation":"x"}');
  // Fix 1: the failed re-run cleared the suggestion from "Use reply as text".
  _check(
    !_has('srs-field-ai-result') &&
        !_has('srs-field-ai-replace') &&
        !_has('srs-field-ai-append'),
    'failed re-run cleared the previous suggestion (no Append / Replace)',
  );
  // Fix 9: this prompt has no {{instruction}}: suggest retry / edit prompt.
  _check(
    _selectable('srs-field-ai-reply-error-text') ==
        t.srs_note_field_ai_reply_empty_retry,
    'blank structured value -> empty message (no-instruction wording)',
    _has('srs-field-ai-reply-error-text')
        ? _selectable('srs-field-ai-reply-error-text')
        : 'no error card',
  );
  _check(!_has('srs-field-ai-use-as-text'), 'no "use as text" for empty');
  await _shot(tester, '17-empty-reply-${c.look}');
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
  _check(
    c.fieldModel('SentenceTranslation') == fieldBefore,
    'dismiss after use-as-text wrote nothing',
  );
}

Future<void> _s5And6Variants(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteA);
  await c.openSheet();
  final int v0 = c.actions.knownVariants.length;
  final AiSrsFieldActionPrompt translateNow = c.actions.promptFor(
    const AiSrsFieldAction(AiSrsFieldTask.translate),
  );
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-new-variant'),
    'sheet › New variant',
    done: () => _has('srs-field-ai-new-variant-sheet'),
  );
  await _until(tester, () => _has('srs-field-ai-new-variant-sheet'));
  await _shot(tester, '18-new-variant-sheet-${c.look}');
  _logTexts('new variant sheet', _key('srs-field-ai-new-variant-sheet'));
  final double yTranslate = tester
      .getTopLeft(_key('srs-field-ai-new-variant-group-translate'))
      .dy;
  final double yCustom = tester
      .getTopLeft(_key('srs-field-ai-new-variant-group-custom'))
      .dy;
  _check(yTranslate < yCustom, 'current task group listed first');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-new-variant-copy'),
    'new variant › Copy of this prompt',
    done: () => _has('srs-field-ai-prompt-editor'),
  );
  await _until(tester, () => _has('srs-field-ai-prompt-editor'));
  await _pumpFor(tester, const Duration(milliseconds: 600));
  _check(c.actions.knownVariants.length == v0 + 1, 'copy created a variant');
  final AiSrsFieldVariant copy = c.actions.knownVariants.last;
  _check(
    copy.task == AiSrsFieldTask.translate && copy.prompt == translateNow,
    'copy = translate prompt (all three parts)',
    copy.name,
  );
  _check(
    c.actions
            .variantsFor(AiSrsFieldTask.translate)
            .map((AiSrsFieldVariant v) {
              return v.name.toLowerCase();
            })
            .toSet()
            .length ==
        c.actions.variantsFor(AiSrsFieldTask.translate).length,
    'copy got a unique default name',
    copy.name,
  );
  _check(_has('srs-field-ai-prompt-name'), 'variant editor has a name field');
  await _shot(tester, '19-editor-copy-variant-${c.look}');
  await c.closePromptEditor();
  _check(_has('srs-field-ai-variant'), 'variant dropdown shown in sheet');
  await _shot(tester, '20-sheet-with-variant-${c.look}');

  Future<void> fromSample(String id, String name) async {
    await _press(
      tester,
      c.d,
      _key('srs-field-ai-new-variant'),
      'sheet › New variant',
      done: () => _has('srs-field-ai-new-variant-sheet'),
    );
    await _until(tester, () => _has('srs-field-ai-new-variant-sheet'));
    await _pumpFor(tester, const Duration(milliseconds: 600));
    _ensureVisible('srs-field-ai-new-variant-$id');
    await _pumpFor(tester, const Duration(milliseconds: 300));
    await _press(
      tester,
      c.d,
      _key('srs-field-ai-new-variant-$id'),
      'new variant › sample',
      maxTabs: 80,
      done: () => _has('srs-field-ai-prompt-editor'),
    );
    await _until(tester, () => _has('srs-field-ai-prompt-editor'));
    await _pumpFor(tester, const Duration(milliseconds: 600));
    final AiSrsFieldSample sample = kAiSrsFieldSamples.firstWhere(
      (AiSrsFieldSample s) => s.id == id,
    );
    final AiSrsFieldVariant v = c.actions.knownVariants.last;
    _check(
      v.task == AiSrsFieldTask.custom &&
          v.prompt.template == sample.template &&
          v.prompt.mode == sample.mode,
      'sample "$name" -> variant under Custom with its template/mode',
      '${v.task} ${v.name}',
    );
    _logTexts('sample editor', _key('srs-field-ai-prompt-editor'));
  }

  await fromSample('sample.custom.example_sentence', 'New example sentence');
  await _shot(tester, '21-editor-sample-example-${c.look}');
  await c.closePromptEditor();
  await fromSample('sample.custom.recall_hint', 'Recall hint');
  await c.closePromptEditor();
  // Fix 8: the same sample again gets a numbered name, and renaming it back to
  // the taken name warns (helper text + confirm on save).
  final String recallName = kAiSrsFieldSamples
      .firstWhere((AiSrsFieldSample s) => s.id == 'sample.custom.recall_hint')
      .name;
  await fromSample('sample.custom.recall_hint', 'Recall hint (again)');
  final String numbered = t.srs_field_ai_prompt_name_numbered(
    name: recallName,
    n: 2,
  );
  _check(
    c.actions.knownVariants.last.name == numbered,
    'second "Recall hint" is numbered',
    c.actions.knownVariants.last.name,
  );
  await tester.enterText(_key('srs-field-ai-prompt-name'), recallName);
  await _pumpFor(tester, const Duration(milliseconds: 400));
  final String taken = t.srs_field_ai_prompt_name_taken(
    task: t.srs_note_field_ai_custom,
    name: recallName,
  );
  _check(
    tester
            .widget<FushiTextField>(_key('srs-field-ai-prompt-name'))
            .helperText ==
        taken,
    'name field warns the name is taken',
  );
  _ensureVisible('srs-field-ai-prompt-name');
  await _shot(tester, '22a-editor-name-taken-${c.look}');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-prompt-save'),
    'editor › Save',
    done: () =>
        find.text(t.srs_field_ai_prompt_name_taken_title).evaluate().isNotEmpty,
  );
  _check(
    await _until(
      tester,
      () => find
          .text(t.srs_field_ai_prompt_name_taken_title)
          .evaluate()
          .isNotEmpty,
    ),
    'save with a taken name asks first',
  );
  await _shot(tester, '22b-name-taken-confirm-${c.look}');
  await _press(
    tester,
    c.d,
    find.text(t.cancel).last,
    'name taken › Cancel',
    done: () =>
        find.text(t.srs_field_ai_prompt_name_taken_title).evaluate().isEmpty,
  );
  _check(
    await _until(
      tester,
      () =>
          find.text(t.srs_field_ai_prompt_name_taken_title).evaluate().isEmpty,
    ),
    'Cancel closed the confirm',
  );
  _check(
    c.actions.knownVariants.last.name == numbered,
    'cancel kept the unique name',
    c.actions.knownVariants.last.name,
  );
  // Put the unique name back so the editor closes clean. Set it on the field's
  // controller: the name field is scrolled under the page header by now, and
  // enterText's focusing tap would land on the header instead.
  (tester.widget(
                find.descendant(
                  of: _key('srs-field-ai-prompt-name'),
                  matching: find.byType(EditableText),
                ),
              )
              as EditableText)
          .controller
          .text =
      numbered;
  await _pumpFor(tester, const Duration(milliseconds: 400));
  _check(
    tester
            .widget<FushiTextField>(_key('srs-field-ai-prompt-name'))
            .helperText ==
        null,
    'warning gone once the name is unique again',
  );
  await c.closePromptEditor();
  await _shot(tester, '22-sheet-recall-hint-${c.look}');
  _logTexts('sheet (recall hint)', _key('srs-field-ai-sheet'));
  _check(
    _enabled('srs-field-ai-run'),
    'Run on (recall hint has no instruction)',
  );
  await c.run('A sudden awareness of something');
  final int i = c.ai.requests.length - 1;
  const String recallUser =
      'Write a hint for this card that helps recall 気づく without containing '
      'it or its reading. At most 12 words, in English.\n\n'
      'Meaning: to notice; to realize\n'
      'Sentence: $_sentenceA';
  final String wantRecall = recallUser.replaceAll('English', c.lang);
  _check(c.ai.user(i) == wantRecall, 'recall hint request', c.ai.user(i));
  _check(
    c.ai.system(i) ==
        c.systemFor(kAiSrsFieldGuidance, AiSrsFieldResponseMode.plain),
    'recall hint system = guidance + plain rules',
  );
  _check(
    _selectable('srs-field-ai-result-text') ==
        'A sudden awareness of something',
    'plain suggestion rendered',
  );
  await _shot(tester, '23-recall-hint-result-${c.look}');

  // S6: fenced + multi-line plain reply.
  _scenario = 'S6 plain fenced/multiline';
  // Plain reply that sanitizes to nothing -> empty error (recall hint = plain).
  await c.run('<b></b>');
  _check(
    _has('srs-field-ai-reply-error'),
    'only-tags plain reply -> empty message',
  );
  // Fix 1: the failed Again must not leave the previous suggestion applicable.
  _check(
    !_has('srs-field-ai-result') && !_has('srs-field-ai-replace'),
    'failed Again cleared the previous suggestion',
  );
  _check(
    _selectable('srs-field-ai-reply-error-text') ==
        t.srs_note_field_ai_reply_empty_retry,
    'empty reply wording fits a prompt without instruction',
  );
  await _shot(tester, '23b-plain-empty-reply-${c.look}');
  await c.run('```html\nLine one\nLine two\n```');
  _check(
    _selectable('srs-field-ai-result-text') == 'Line one\nLine two',
    'fence stripped, lines kept',
    _selectable('srs-field-ai-result-text'),
  );
  await _shot(tester, '24-fenced-reply-${c.look}');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-replace'),
    'sheet › Replace',
    done: () => !_has('srs-field-ai-sheet'),
  );
  await _until(tester, () => !_has('srs-field-ai-sheet'));
  _check(
    c.fieldModel('SentenceTranslation') == 'Line one<br>Line two',
    'multi-line -> <br> in the field',
    c.fieldModel('SentenceTranslation'),
  );
}

Future<void> _s8bCustomEmpty(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteA);
  await c.openSheet();
  final Finder sheet = _key('srs-field-ai-sheet');
  // Switching task resets the variant: Custom = its built-in default.
  await _selectSegment<AiSrsFieldTask>(
    tester,
    c.d,
    sheet,
    AiSrsFieldTask.rewrite,
    'sheet › task selector',
    t.srs_note_field_ai_rewrite,
    AiSrsFieldTask.values,
  );
  await _selectSegment<AiSrsFieldTask>(
    tester,
    c.d,
    sheet,
    AiSrsFieldTask.custom,
    'sheet › task selector',
    t.srs_note_field_ai_custom,
    AiSrsFieldTask.values,
  );
  _check(_enabled('srs-field-ai-instruction'), 'custom: instruction enabled');
  _check(!_enabled('srs-field-ai-run'), 'custom + empty instruction: Run off');
  await _shot(tester, '25-custom-empty-run-disabled-${c.look}');
  await tester.enterText(
    _key('srs-field-ai-instruction'),
    'Write a short mnemonic.',
  );
  await _pumpFor(tester, const Duration(milliseconds: 400));
  _check(_enabled('srs-field-ai-run'), 'custom + instruction: Run on');
  await _shot(tester, '26-custom-with-instruction-${c.look}');
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
}

Future<void> _openSettings(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.popToRoot();
  unawaited(
    c.nav.push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) =>
            SettingsDetailPage(destination: buildAiDestination()),
      ),
    ),
  );
  await _until(
    tester,
    () => find.byType(SettingsDetailPage).evaluate().isNotEmpty,
  );
  await _pumpFor(tester, const Duration(seconds: 1));
  final Finder header = find.text(t.ai_field_actions_section);
  for (int i = 0; i < 30 && header.evaluate().isEmpty; i++) {
    final Finder scroll = find.descendant(
      of: find.byType(SettingsDetailPage),
      matching: find.byType(Scrollable),
    );
    if (scroll.evaluate().isEmpty) break;
    final ScrollableState s = tester.state<ScrollableState>(scroll.first);
    s.position.jumpTo(
      (s.position.pixels + 400).clamp(0, s.position.maxScrollExtent),
    );
    await _pumpFor(tester, const Duration(milliseconds: 200));
  }
  if (header.evaluate().isNotEmpty) {
    unawaited(
      Scrollable.ensureVisible(
        header.evaluate().first,
        alignment: 0.2,
        duration: Duration.zero,
      ),
    );
    await _pumpFor(tester, const Duration(milliseconds: 400));
  }
  _check(header.evaluate().isNotEmpty, 'Card field AI section visible');
}

Future<void> _expandFieldSection(_Ctx c) async {
  if (_has('ai-field-prompt-task.translate')) return;
  await _press(
    c.tester,
    c.d,
    find.text(t.ai_field_actions_section),
    'settings › Card field AI header',
    maxTabs: 120,
    done: () => _has('ai-field-prompt-task.translate'),
  );
  await _until(c.tester, () => _has('ai-field-prompt-task.translate'));
  _ensureVisible('ai-field-prompt-task.define');
  await _pumpFor(c.tester, const Duration(milliseconds: 500));
}

Future<void> _s11Settings(_Ctx c, {required bool reset}) async {
  final WidgetTester tester = c.tester;
  await _openSettings(c);
  final String modified1 = t.settings_section_modified_count(n: 1);
  if (reset) {
    _check(
      find.text(modified1).evaluate().isNotEmpty,
      'collapsed section shows "$modified1"',
      _texts(find.byType(SettingsDetailPage)),
    );
  }
  await _shot(tester, '27-settings-collapsed-${c.look}');
  await _expandFieldSection(c);
  await _shot(tester, '28-settings-expanded-${c.look}');
  _logTexts('settings', find.byType(SettingsDetailPage));
  for (final String id in <String>[
    'task.define',
    'task.translate',
    'task.rewrite',
    'task.custom',
  ]) {
    _check(_has('ai-field-prompt-$id'), 'row $id');
  }
  _check(
    find.text(t.ai_output_language).evaluate().isNotEmpty,
    'output language row',
  );
  final List<AiSrsFieldVariant> vs = c.actions.knownVariants;
  _check(
    vs.every(
      (AiSrsFieldVariant v) => _key(
        'ai-field-prompt-variant-${v.id}',
        skipOffstage: false,
      ).evaluate().isNotEmpty,
    ),
    'variant rows (${vs.length})',
  );
  _ensureVisible('ai-field-prompt-task.custom');
  await _shot(tester, '29-settings-rows-${c.look}');
  if (!reset) return;

  // Reset the edited Translate from the settings editor (sample-note preview).
  await _press(
    tester,
    c.d,
    _key('ai-field-prompt-task.translate'),
    'settings › Translate row',
    maxTabs: 120,
    done: () => _has('srs-field-ai-prompt-editor'),
  );
  await _until(tester, () => _has('srs-field-ai-prompt-editor'));
  await _pumpFor(tester, const Duration(milliseconds: 800));
  _check(
    find.text(t.srs_field_ai_prompt_preview_sample).evaluate().isNotEmpty,
    'settings editor previews the sample note',
  );
  await _shot(tester, '30-settings-editor-${c.look}');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-prompt-reset'),
    'editor › Reset to default',
    done: () =>
        find.text(t.srs_field_ai_prompt_reset_confirm).evaluate().isNotEmpty,
  );
  await _until(
    tester,
    () => find.text(t.srs_field_ai_prompt_reset_confirm).evaluate().isNotEmpty,
  );
  await _shot(tester, '31-reset-confirm-${c.look}');
  // The confirm action is autofocused: Enter confirms.
  await c.d.activate();
  await _until(tester, () => !c.actions.isOverridden('task.translate'));
  _check(!c.actions.isOverridden('task.translate'), 'Reset removed override');
  final String text =
      (tester.widget(
                find.descendant(
                  of: _key('srs-field-ai-prompt-text'),
                  matching: find.byType(EditableText),
                ),
              )
              as EditableText)
          .controller
          .text;
  _check(text == kAiSrsFieldTranslateTemplate, 'editor shows default again');
  await c.closePromptEditor();
  await _pumpFor(tester, const Duration(milliseconds: 600));
  _check(
    find.text(modified1).evaluate().isEmpty,
    'modified count gone after reset',
  );
  await _shot(tester, '32-settings-after-reset-${c.look}');
}

Future<void> _s9SecondNote(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteB);
  await c.openSheet();
  await c.run(
    '{"value":"Careless of me, huh…","explanation":"Fragment kept; speaker '
    'implied."}',
  );
  final int i = c.ai.requests.length - 1;
  final Map<String, Object?>? note = c.splitNoteJson(
    c.ai.user(i),
    c.expandFixed(kAiSrsFieldTranslateTemplate),
  );
  _check(note != null, 'user == default translate template + note');
  if (note != null) {
    _check(
      _contentOf(note, 'Sentence') == _sentenceB,
      'うっかりかあ intact (no <b>)',
      _contentOf(note, 'Sentence'),
    );
  }
  _check(c.ai.user(i).contains('"うっかりかあ"'), 'sentence JSON-quoted');
  _check(
    c.ai.system(i) ==
        c.systemFor(kAiSrsFieldGuidance, AiSrsFieldResponseMode.structured),
    'system == default guidance + rules',
  );
  _check(
    _selectable('srs-field-ai-result-text') == 'Careless of me, huh…',
    'suggestion rendered',
  );
  await _shot(tester, '33-second-note-${c.look}');
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
}

Future<void> _s10OverLimit(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await c.openEditor(c.noteC);
  await c.openSheet();
  _check(
    _has('srs-field-ai-notice-truncated'),
    '{{note}} truncation notice for the 30k Glossary',
  );
  _log(
    'truncation notice: ${_has('srs-field-ai-notice-truncated') ? _selectable('srs-field-ai-notice-truncated') : '-'}',
  );
  _check(_enabled('srs-field-ai-run'), 'truncated (not over limit): Run on');
  await _shot(tester, '34-truncation-notice-${c.look}');
  final int n0 = c.ai.requests.length;
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-new-variant'),
    'sheet › New variant',
    done: () => _has('srs-field-ai-new-variant-sheet'),
  );
  await _until(tester, () => _has('srs-field-ai-new-variant-sheet'));
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-new-variant-copy'),
    'new variant › Copy of this prompt',
    done: () => _has('srs-field-ai-prompt-editor'),
  );
  await _until(tester, () => _has('srs-field-ai-prompt-editor'));
  await _pumpFor(tester, const Duration(milliseconds: 600));
  await tester.enterText(
    _key('srs-field-ai-prompt-text'),
    'Shorten:\n{{Glossary}}',
  );
  await _pumpFor(tester, const Duration(milliseconds: 500));
  _check(
    _selectable('srs-field-ai-prompt-preview-user').contains('… [truncated: '),
    'placeholder truncation is visible in the preview text',
  );
  await tester.enterText(
    _key('srs-field-ai-prompt-text'),
    'Shorten:\n${'{{Glossary}}\n' * 13}',
  );
  await _pumpFor(tester, const Duration(milliseconds: 500));
  _check(_has('srs-field-ai-notice-over-limit'), 'editor over-limit warning');
  _ensureVisible('srs-field-ai-notice-over-limit');
  await _shot(tester, '35-editor-over-limit-${c.look}');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-prompt-save'),
    'editor › Save',
    done: () => !_enabled('srs-field-ai-prompt-save'),
  );
  await _pumpFor(tester, const Duration(milliseconds: 400));
  await c.closePromptEditor();
  _check(_has('srs-field-ai-notice-over-limit'), 'sheet over-limit error');
  _check(!_enabled('srs-field-ai-run'), 'over limit: Run off');
  // A disabled button takes no focus; give any stray send time to land.
  await _pumpFor(tester, const Duration(seconds: 2));
  _check(
    c.ai.requests.length == n0,
    'server got nothing',
    c.ai.requests.length,
  );
  _log(
    'over-limit notice: ${_has('srs-field-ai-notice-over-limit') ? _selectable('srs-field-ai-notice-over-limit') : '-'}',
  );
  await _shot(tester, '36-sheet-over-limit-${c.look}');
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
}

Future<void> _s12AppleVisuals(_Ctx c) async {
  final WidgetTester tester = c.tester;
  await _s1Sheet(c);
  await c.openEditor(c.noteA);
  await c.openSheet();
  await c.run(_translateReply);
  await _shot(tester, '03-translate-result-${c.look}');
  await _press(
    tester,
    c.d,
    _key('ai-saved-prompts-srs_field'),
    'sheet › presets button',
    done: () => _has('ai-saved-prompt-sheet'),
  );
  await _until(tester, () => _has('ai-saved-prompt-sheet'));
  await _shot(tester, '02-presets-translate-${c.look}');
  await _dismiss(tester, c.d, 'ai-saved-prompt-sheet', 'presets sheet');
  await c.openPromptEditorFromSheet();
  await _shot(tester, '05-prompt-editor-top-${c.look}');
  _ensureVisible('srs-field-ai-prompt-preview-user-card');
  await _shot(tester, '06-prompt-editor-preview-${c.look}');
  _ensureVisible('srs-field-ai-prompt-preview-rules-card');
  await _shot(tester, '07-prompt-editor-rules-${c.look}');
  _ensureVisible('srs-field-ai-prompt-insert');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-prompt-insert'),
    'editor › Insert placeholder',
    done: () => _has('srs-field-ai-placeholder-sheet'),
  );
  await _until(tester, () => _has('srs-field-ai-placeholder-sheet'));
  await _shot(tester, '09-placeholder-picker-${c.look}');
  await _dismiss(
    tester,
    c.d,
    'srs-field-ai-placeholder-sheet',
    'placeholder picker',
  );
  await c.closePromptEditor();
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-new-variant'),
    'sheet › New variant',
    done: () => _has('srs-field-ai-new-variant-sheet'),
  );
  await _until(tester, () => _has('srs-field-ai-new-variant-sheet'));
  await _shot(tester, '18-new-variant-sheet-${c.look}');
  await _dismiss(tester, c.d, 'srs-field-ai-new-variant-sheet', 'new variant');
  await c.run('Sure: {broken');
  await _shot(tester, '14-malformed-reply-${c.look}');
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
  await _s11Settings(c, reset: false);
}

/// Dark mode: sheet with a result, editor preview, new-variant sheet, reply
/// error -- in the current design system ([c.look]).
Future<void> _sDark(_Ctx c) async {
  final WidgetTester tester = c.tester;
  final String look = c.look;
  _check(
    Theme.of(c.nav.context).brightness == Brightness.dark,
    'theme is dark',
  );
  await c.openEditor(c.noteA);
  await c.openSheet();
  await c.run(_translateReply);
  _check(_has('srs-field-ai-result'), 'result shown (dark)');
  _check(
    _boldSpans('srs-field-ai-result-text').join('|') == 'noticed',
    'bold kept in dark',
  );
  await _shot(tester, 'D1-sheet-result-dark-$look');
  await c.openPromptEditorFromSheet();
  await _shot(tester, 'D2-editor-top-dark-$look');
  _ensureVisible('srs-field-ai-prompt-preview-user-title');
  await _shot(tester, 'D3-editor-preview-dark-$look');
  _ensureVisible('srs-field-ai-prompt-preview-rules-card');
  await _shot(tester, 'D4-editor-rules-dark-$look');
  await c.closePromptEditor();
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-new-variant'),
    'sheet › New variant',
    done: () => _has('srs-field-ai-new-variant-sheet'),
  );
  await _until(tester, () => _has('srs-field-ai-new-variant-sheet'));
  await _shot(tester, 'D5-new-variant-dark-$look');
  await _dismiss(tester, c.d, 'srs-field-ai-new-variant-sheet', 'new variant');
  await c.run('Sure: {broken');
  _check(_has('srs-field-ai-reply-error'), 'reply error (dark)');
  _check(!_has('srs-field-ai-result'), 'no stale result under the error');
  await _press(
    tester,
    c.d,
    _key('srs-field-ai-show-reply'),
    'sheet › Show reply',
    done: () => _has('srs-field-ai-raw-reply'),
  );
  await _until(tester, () => _has('srs-field-ai-raw-reply'));
  await _shot(tester, 'D6-reply-error-dark-$look');
  await _dismiss(tester, c.d, 'srs-field-ai-sheet', 'field AI sheet');
}

// ─────────────────────────── test ───────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('card field AI end to end (M3E + Apple)', (
    WidgetTester tester,
  ) async {
    final List<String> flutterErrors = <String>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      flutterErrors.add(details.exceptionAsString());
      _log('FlutterError: ${details.exceptionAsString().split('\n').first}');
      oldHandler?.call(details);
    };
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: 'home within 90 s');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    final bool focusNavBefore = appModel.experimentalFocusNavigationEnabled;
    await enableFocusNavigation(tester);

    final String designBefore = appModel.themeNotifier.designSystem;
    final String brightnessBefore = appModel.themeNotifier.brightnessMode;
    final String providersBefore =
        appModel.prefsRepo.getPref('ai_providers', defaultValue: '') as String;
    final AiFeatureAssignments assignBefore =
        appModel.prefsRepo.storedAiFeatureAssignments;
    final AiSrsFieldActions actionsBefore = appModel.prefsRepo.aiFieldActions;
    final String outLangBefore = appModel.prefsRepo.aiOutputLanguage;
    final bool aiBefore = appModel.moduleVisibility.isEnabled(ModuleId.ai);
    final bool srsBefore = appModel.moduleVisibility.isEnabled(ModuleId.srs);

    final _FakeAi ai = _FakeAi();
    await ai.start();
    _log('fake AI on 127.0.0.1:${ai.port}');
    try {
      await appModel.setModuleEnabled(ModuleId.srs, true);
      await appModel.setModuleEnabled(ModuleId.ai, true);
      final AiProviderConfig provider = AiProviderConfig(
        id: 'field-ai-itest',
        presetId: kAiCustomPresetId,
        name: 'Field AI itest',
        baseUrl: Uri.parse('http://127.0.0.1:${ai.port}/v1'),
        apiKey: 'dummy-key',
        model: 'fake-model',
      );
      await appModel.prefsRepo.setAiProviders(<AiProviderConfig>[provider]);
      await appModel.prefsRepo.setAiFeatureAssignments(
        appModel.prefsRepo.storedAiFeatureAssignments.withAssignment(
          AiFeature.srsNoteField,
          provider.id,
        ),
      );
      await appModel.prefsRepo.setAiFieldActions(AiSrsFieldActions.empty);
      await appModel.themeNotifier.setDesignSystem('material');
      await _pumpFor(tester, const Duration(seconds: 1));
      _check(
        appModel.prefsRepo
                .resolveAiFeatureProvider(AiFeature.srsNoteField)
                ?.id ==
            provider.id,
        'provider resolves for srsNoteField',
      );

      final BuildContext rootContext = appModel.navigatorKey.currentContext!;
      final ProviderContainer container = ProviderScope.containerOf(
        rootContext,
      );
      final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
      await store.ensureBuiltins();
      final _Ctx c = _Ctx(tester, appModel, store, FocusDriver(tester), ai);
      c.fieldIdByName = <String, String>{
        for (final String name in <String>[
          'Term',
          'TermReading',
          'MainDefinition',
          'Glossary',
          'Sentence',
          'SentenceTranslation',
          'Hint',
        ])
          name: srsFushiCardFieldId(store.profileUid, name),
      };
      c.noteA = await c.createNote(_noteA());
      c.noteB = await c.createNote(_noteB());
      c.noteC = await c.createNote(_noteC());
      container.read(srsRevisionProvider.notifier).state++;
      _log('notes A=${c.noteA} B=${c.noteB} C=${c.noteC} lang=${c.lang}');

      await _guard(c, 'S1 sheet', () => _s1Sheet(c));
      await _guard(c, 'S2 run translate', () => _s2RunTranslate(c));
      await _guard(
        c,
        'S3 preview == request',
        () => _s3PreviewEqualsRequest(c),
      );
      await _guard(c, 'S4 editor UX', () => _s4Editor(c));
      await _guard(
        c,
        'S7+S8a malformed / no instruction',
        () => _s7And8NoInstruction(c),
      );
      await _guard(c, 'S5+S6 new variant / plain', () => _s5And6Variants(c));
      await _guard(c, 'S8b custom empty', () => _s8bCustomEmpty(c));
      await _guard(c, 'S11 settings', () => _s11Settings(c, reset: true));
      await _guard(c, 'S9 second note', () => _s9SecondNote(c));
      await _guard(c, 'S10 over limit', () => _s10OverLimit(c));

      await c.popToRoot();
      c.look = 'apple';
      await appModel.themeNotifier.setDesignSystem('glass');
      await _pumpFor(tester, const Duration(seconds: 2));
      await _guard(c, 'S12 apple visuals', () => _s12AppleVisuals(c));
      await c.popToRoot();

      await appModel.themeNotifier.setBrightnessMode('dark');
      await _pumpFor(tester, const Duration(seconds: 2));
      await _guard(c, 'S13 dark apple', () => _sDark(c));
      await c.popToRoot();
      c.look = 'm3e';
      await appModel.themeNotifier.setDesignSystem('material');
      await _pumpFor(tester, const Duration(seconds: 2));
      await _guard(c, 'S13 dark m3e', () => _sDark(c));
      await c.popToRoot();
    } finally {
      _scenario = 'restore';
      await appModel.themeNotifier.setBrightnessMode(brightnessBefore);
      await appModel.themeNotifier.setDesignSystem(designBefore);
      await appModel.prefsRepo.setPref('ai_providers', providersBefore);
      await appModel.prefsRepo.setAiFeatureAssignments(assignBefore);
      await appModel.prefsRepo.setAiFieldActions(actionsBefore);
      await appModel.prefsRepo.setAiOutputLanguage(outLangBefore);
      await appModel.setModuleEnabled(ModuleId.ai, aiBefore);
      await appModel.setModuleEnabled(ModuleId.srs, srsBefore);
      await appModel.setExperimentalFocusNavigationEnabled(focusNavBefore);
      await ai.close();
      FlutterError.onError = oldHandler;
    }
    _log('requests total=${ai.requests.length}');
    _log('press methods: ${jsonEncode(_pressMethods)}');
    _log('shots: ${_shots.length}');
    _log('flutter errors: ${flutterErrors.length}');
    for (final String e in flutterErrors.take(10)) {
      _log('flutter error: ${e.split('\n').take(3).join(' | ')}');
    }
    _log('failures (${_failures.length}):');
    for (final String f in _failures) {
      _log('  FAIL $f');
    }
    expect(_failures, isEmpty);
    expect(flutterErrors, isEmpty);
  });
}
