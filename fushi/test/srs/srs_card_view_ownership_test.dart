// SRS 复习卡面：手势 / 选区归属与「可见即可播」（反馈 eo2pH56Ont / Z9APuG_imH / HrB0STYm3E）。
//
// - eo2pH56Ont / Z9APuG_imH：SelectionArea 以前包住整个视口（含释义 WebView 平台视图与留白），
//   长按释义 / 留白时 Flutter 选中了最近的原生例句、平台视图拖动要等祖先识别器放弃。现在
//   选区只包原生文字列，释义 WebView 是兄弟节点并自己声明手势（srsCardFaceGestureRecognizers）。
// - HrB0STYm3E：自动播放 / 重播清单与卡面画了什么不是同一来源。原生卡面现在都走
//   srsFushiCardPlan；整面 WebView 卡面由页面上报可见发音（kSrsCardVisibleSoundsScript）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_fushi_card_plan.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_edit.dart' show SrsCardSelection;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show
        FushiCardBlock,
        FushiCardNoteType,
        inlineVideoCoverHtml,
        inlineVideoSentenceAudioHtml;
import 'package:material_ui/material_ui.dart';

import '../helpers/node_runtime.dart';
import '../helpers/test_platform_services.dart';

class _App extends AppModel {
  _App() : super(testPlatformServices());

  SrsCardAppearance value = const SrsCardAppearance();

  @override
  SrsCardAppearance get srsCardAppearance => value;
}

Map<String, String> _fields(Map<String, String> extra) => <String, String>{
  for (final String f in FushiCardNoteType.fields) f: '',
  ...extra,
};

/// 释义 WebView 的替身：与生产平台视图声明同一组识别器（[srsCardFaceGestureRecognizers]）。
class _FakeDefs extends StatelessWidget {
  const _FakeDefs({required this.scrollsInPage, required this.log});

  final bool scrollsInPage;
  final List<String> log;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    key: const ValueKey<String>('fake-defs'),
    behavior: HitTestBehavior.opaque,
    gestures: <Type, GestureRecognizerFactory>{
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            LongPressGestureRecognizer.new,
            (LongPressGestureRecognizer r) =>
                r.onLongPress = () => log.add('longPress'),
          ),
      HorizontalDragGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            HorizontalDragGestureRecognizer.new,
            (HorizontalDragGestureRecognizer r) =>
                r.onStart = (DragStartDetails _) => log.add('hDrag'),
          ),
      if (scrollsInPage)
        VerticalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
              VerticalDragGestureRecognizer.new,
              (VerticalDragGestureRecognizer r) =>
                  r.onStart = (DragStartDetails _) => log.add('vDrag'),
            ),
    },
    child: const ColoredBox(color: Color(0x11000000), child: SizedBox.expand()),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  // ------------------------------------------------------------ HrB0STYm3E 计划矩阵

  group('srsFushiCardPlan：只收看得见的区块里的媒体（HrB0STYm3E）', () {
    const SrsCardAppearance shown = SrsCardAppearance();
    const SrsCardAppearance noPicture = SrsCardAppearance(showPicture: false);

    for (final bool showPicture in <bool>[true, false]) {
      for (final bool clipCarries in <bool>[true, false]) {
        for (final bool sentenceFilled in <bool>[true, false]) {
          test('showPicture=$showPicture clipCarriesSentence=$clipCarries '
              'Sentence=${sentenceFilled ? '有' : '空'}', () {
            final SrsFushiCardPlan plan = srsFushiCardPlan(
              _fields(<String, String>{
                'Term': '飲む',
                'Sentence': sentenceFilled ? '水を飲む' : '',
                'Media': inlineVideoCoverHtml('clip.webm'),
                'TermAudio': '[sound:w1.mp3][sound:w2.mp3]',
                'SentenceAudio': clipCarries
                    ? inlineVideoSentenceAudioHtml('clip.webm')
                    : '[sound:s.mp3]',
              }),
              showPicture ? shown : noPicture,
            );
            final SrsFushiCardMedia m = plan.media;
            expect(plan.shows(FushiCardBlock.picture), showPicture);
            expect(plan.shows(FushiCardBlock.sentence), sentenceFilled);
            expect(m.word, <String>['w1.mp3', 'w2.mp3'], reason: '多段单词音频都在');
            expect(m.clip, showPicture ? 'clip.webm' : isNull);
            final List<String> sentence = !sentenceFilled
                ? const <String>[]
                : clipCarries
                ? const <String>['clip.webm']
                : const <String>['s.mp3'];
            expect(m.sentence, sentence, reason: '例句块不画就没有例句音频');
            // 期望的背面序列：单词 → 例句单元（片段带声时是片段本身）。
            final List<String> unit = showPicture && clipCarries
                ? const <String>['clip.webm']
                : showPicture && !sentenceFilled
                ? const <String>['clip.webm']
                : sentence;
            expect(m.back, <String>['w1.mp3', 'w2.mp3', ...unit]);
            if (!showPicture && !sentenceFilled) {
              expect(m.back, <String>[
                'w1.mp3',
                'w2.mp3',
              ], reason: '图片区关掉、又没有例句块：片段与例句音频一声不出');
            }
          });
        }
      }
    }

    test('听力卡正面那颗发音键按字段取（正面总是画它）', () {
      expect(
        srsFushiCardPlan(
          _fields(<String, String>{
            'IsAudioCard': 'x',
            'TermAudio': '[sound:w.mp3]',
            'SentenceAudio': '[sound:s.mp3]',
          }),
          shown,
        ).media.front,
        <String>['s.mp3'],
      );
      expect(
        srsFushiCardPlan(
          _fields(<String, String>{'TermAudio': '[sound:w.mp3]'}),
          shown,
        ).media.front,
        isEmpty,
        reason: '不是听力卡：正面没有发音键',
      );
    });
  });

  // ------------------------------------------------------------ 平台视图手势声明

  group('卡面 WebView 自己认领手势（eo2pH56Ont / Z9APuG_imH）', () {
    Set<Type> typesOf(Set<Factory<OneSequenceGestureRecognizer>> fs) => <Type>{
      for (final Factory<OneSequenceGestureRecognizer> f in fs) f.type,
    };

    test('页内滚动：长按 + 横拖 + 纵拖；跟内容等高：不认领纵拖', () {
      expect(
        typesOf(srsCardFaceGestureRecognizers(scrollsInPage: true)),
        <Type>{
          LongPressGestureRecognizer,
          HorizontalDragGestureRecognizer,
          VerticalDragGestureRecognizer,
        },
      );
      expect(
        typesOf(srsCardFaceGestureRecognizers(scrollsInPage: false)),
        <Type>{LongPressGestureRecognizer, HorizontalDragGestureRecognizer},
      );
    });

    test('守卫：SrsWebCardFace 的 InAppWebView 传了 gestureRecognizers', () {
      final String src = File(
        'lib/src/pages/implementations/srs/srs_card_face.dart',
      ).readAsStringSync();
      final int at = src.indexOf('child: InAppWebView(');
      expect(at, greaterThan(0));
      final String head = src.substring(at, at + 600);
      expect(
        head,
        contains('gestureRecognizers: srsCardFaceGestureRecognizers('),
        reason: '不声明时 Android 退化成空集合，平台视图抢不到长按 / 拖动',
      );
    });
  });

  // ------------------------------------------------------------ 原生卡面选区归属

  group('SrsFushiCardView：选区只包原生文字，释义 WebView 不在选区里', () {
    Future<({List<String> selections, List<String> defsLog})> pump(
      WidgetTester tester, {
      required Size size,
      required bool answer,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<String> selections = <String>[];
      final List<String> defsLog = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => _App()),
            srsMediaStoreProvider.overrideWith(
              (Ref ref) async => null as SrsMediaStore?,
            ),
            srsCardFaceBuilderProvider.overrideWithValue(
              (BuildContext context, SrsCardFace face) => _FakeDefs(
                scrollsInPage: face.onContentHeight == null,
                log: defsLog,
              ),
            ),
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
              home: Scaffold(
                body: SrsFushiCardView(
                  face: SrsCardFace(
                    cardId: 'c1',
                    showingAnswer: answer,
                    bodyHtml: '',
                    css: FushiCardNoteType.template.css,
                    languageCode: 'ja',
                    onBridgeKey: (_) {},
                    onEditSelection: (SrsCardSelection sel) =>
                        selections.add(sel.text),
                  ),
                  fields: _fields(<String, String>{
                    'Term': '飲む',
                    'Sentence': '水を飲む',
                    'MainDefinition': 'to drink',
                  }),
                  definitionsHtml: '<div class="fc-defs-only">defs</div>',
                  topInset: 0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
      return (selections: selections, defsLog: defsLog);
    }

    Finder selectionAbove(Finder f) =>
        find.ancestor(of: f, matching: find.byType(SelectionArea));

    for (final (String name, Size size) in <(String, Size)>[
      ('窄版式', const Size(390, 844)),
      ('宽版式', const Size(1047, 698)),
    ]) {
      testWidgets('$name：释义不是任何 SelectionArea 的后代，原生文字是', (
        WidgetTester tester,
      ) async {
        await pump(tester, size: size, answer: true);
        expect(
          selectionAbove(find.byKey(const ValueKey<String>('fake-defs'))),
          findsNothing,
        );
        expect(
          selectionAbove(find.byKey(const ValueKey<String>('srs-fushi-term'))),
          findsOneWidget,
        );
        expect(
          selectionAbove(
            find.byKey(const ValueKey<String>('srs-fushi-sentence')),
          ),
          findsOneWidget,
        );
      });

      testWidgets('$name：长按释义 = 释义自己的长按，不选中原生例句', (WidgetTester tester) async {
        final ({List<String> selections, List<String> defsLog}) r = await pump(
          tester,
          size: size,
          answer: true,
        );
        await tester.longPress(find.byKey(const ValueKey<String>('fake-defs')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(r.defsLog, contains('longPress'));
        expect(r.selections, isEmpty, reason: '以前兜底选中了最近的例句');
      });

      testWidgets('$name：长按底部留白不触发 nearest 兜底选中', (WidgetTester tester) async {
        final ({List<String> selections, List<String> defsLog}) r = await pump(
          tester,
          size: size,
          answer: true,
        );
        // 左下角：窄版式在释义与页脚之下的留白，宽版式是左栏内容列下方的留白。
        await tester.longPressAt(Offset(40, size.height - 6));
        await tester.pump(const Duration(milliseconds: 300));
        expect(r.selections, isEmpty);
      });

      testWidgets('$name：长按例句文字照常选中并上报（正向用例）', (WidgetTester tester) async {
        final ({List<String> selections, List<String> defsLog}) r = await pump(
          tester,
          size: size,
          answer: true,
        );
        await tester.longPress(
          find.byKey(const ValueKey<String>('srs-fushi-sentence')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(r.selections, isNotEmpty);
        expect(r.defsLog, isEmpty);
      });
    }

    testWidgets('宽版式：在释义栏里纵向拖，第一个越过阈值的移动之前就归释义（不等祖先放弃）', (
      WidgetTester tester,
    ) async {
      final ({List<String> selections, List<String> defsLog}) r = await pump(
        tester,
        size: const Size(1047, 698),
        answer: true,
      );
      final Offset c = tester.getCenter(
        find.byKey(const ValueKey<String>('fake-defs')),
      );
      final TestGesture g = await tester.startGesture(c);
      // 纵拖识别器的阈值是 kTouchSlop（18）：刚越过就该开始，不需要祖先先放弃。
      await g.moveBy(const Offset(0, kTouchSlop + 1));
      await tester.pump();
      expect(r.defsLog, contains('vDrag'));
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.selections, isEmpty);
    });

    testWidgets('正面：预热中的释义不在选区里', (WidgetTester tester) async {
      await pump(tester, size: const Size(390, 844), answer: false);
      expect(
        selectionAbove(
          find.byKey(const ValueKey<String>('fake-defs'), skipOffstage: false),
        ),
        findsNothing,
      );
    });
  });

  // ------------------------------------------------------------ 原生卡面画的 = 计划里的

  group('SrsFushiCardView 画出的发音键 / 片段与 srsFushiCardPlan 一致（HrB0STYm3E）', () {
    testWidgets('关了显示图片、例句为空：不画片段与例句键，计划里也没有', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Map<String, String> fields = _fields(<String, String>{
        'Term': '飲む',
        'Media': inlineVideoCoverHtml('clip.webm'),
        'TermAudio': '[sound:w.mp3]',
        'SentenceAudio': '[sound:s.mp3]',
      });
      const SrsCardAppearance appearance = SrsCardAppearance(
        showPicture: false,
      );
      final _App app = _App()..value = appearance;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => app),
            srsMediaStoreProvider.overrideWith(
              (Ref ref) async => null as SrsMediaStore?,
            ),
            srsCardFaceBuilderProvider.overrideWithValue(
              (BuildContext context, SrsCardFace face) =>
                  const SizedBox(key: ValueKey<String>('fake-defs')),
            ),
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
              home: Scaffold(
                body: SrsFushiCardView(
                  face: SrsCardFace(
                    cardId: 'c1',
                    showingAnswer: true,
                    bodyHtml: '',
                    css: FushiCardNoteType.template.css,
                    languageCode: 'ja',
                    onBridgeKey: (_) {},
                  ),
                  fields: fields,
                  definitionsHtml: '',
                  topInset: 0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
      final SrsFushiCardMedia plan = srsFushiCardPlan(fields, appearance).media;
      expect(
        find.byKey(const ValueKey<String>('srs-fushi-picture')),
        findsNothing,
      );
      expect(plan.clip, isNull);
      expect(
        find.byKey(const ValueKey<String>('srs-fushi-sentence-audio')),
        findsNothing,
      );
      expect(plan.sentenceUnit, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('srs-fushi-word-audio')),
        findsOneWidget,
      );
      expect(plan.back, <String>['w.mp3'], reason: '自动播放 / 重播只剩画出来的单词键');
    });
  });

  // ------------------------------------------------------------ 页内可见发音上报

  final NodeTestRuntime node = NodeTestRuntime.probe();
  test(
    '可见发音脚本（node）：隐藏容器 / 收起的 details / visibility:hidden / opacity:0 不上报',
    skip: node.skipReason,
    () async {
      const String js =
          '''
const assert = require('node:assert/strict');
globalThis.window = globalThis;
function el(tag, opts){
  const o = Object.assign({ style: {}, rects: 1, attrs: {}, open: false }, opts || {});
  return {
    nodeType: 1, tagName: tag, parentElement: null, open: o.open, _style: o.style,
    _rects: o.rects,
    getClientRects(){ return new Array(this._rects); },
    getAttribute(n){ return o.attrs[n] === undefined ? null : o.attrs[n]; },
  };
}
function nest(parent, child){ child.parentElement = parent; return child; }
window.getComputedStyle = n => Object.assign(
  { display: 'block', visibility: 'visible', opacity: '1' }, n._style);
const root = el('DIV');
const sounds = [];
function sound(name, parent, opts){
  const b = nest(parent, el('BUTTON', Object.assign({ attrs: { 'data-sound': name } }, opts || {})));
  sounds.push(b);
  return b;
}
sound('a.mp3', root);
const hidden = nest(root, el('DIV', { style: { display: 'none' }, rects: 0 }));
sound('hidden.mp3', hidden, { rects: 0 });
const details = nest(root, el('DETAILS', { open: false }));
const summary = nest(details, el('SUMMARY'));
sound('summary.mp3', summary);
const body = nest(details, el('DIV'));
sound('collapsed.mp3', body);
sound('invisible.mp3', root, { style: { visibility: 'hidden' } });
const faded = nest(root, el('DIV', { style: { opacity: '0' } }));
sound('faded.mp3', faded);
sound('a.mp3', root);
root.querySelectorAll = sel => { assert.equal(sel, '[data-sound]'); return sounds; };
$kSrsCardVisibleSoundsScript
assert.deepEqual(window.__fushiSrsVisibleSounds(root),
  ['a.mp3', 'summary.mp3', 'a.mp3']);
assert.deepEqual(window.__fushiSrsVisibleSounds(null), []);
''';
      final Directory dir = Directory.systemTemp.createTempSync('srs-vis-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync(js);
        final ProcessResult result = await Process.run(
          node.requireNode(),
          <String>[script.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );

  test('外壳：可见发音脚本先装好；卡片脚本跑完、换主题后都上报，换卡前下发这一面的标记', () {
    final String shell = srsCardShellHtml(themeCss: '', classes: '');
    expect(shell, contains(kSrsCardVisibleSoundsScript));
    expect(kSrsCardShellScript, contains("'$kSrsVisibleSoundsHandler'"));
    expect(
      RegExp(
        r'hostLayout\(\);(\s*//[^\n]*)*\s*reportSounds\(\);',
      ).allMatches(kSrsCardShellScript),
      hasLength(2),
      reason: 'finish（卡片脚本跑完）与 __fushiSrsSetTheme 各报一次',
    );
    const SrsCardFaceDocument doc = SrsCardFaceDocument(
      themeCss: '',
      classes: '',
      cardId: 'c"1',
      showingAnswer: true,
      cardCss: '',
      bodyHtml: '[sound:a.mp3]',
    );
    final String full = doc.fullCardScript;
    final String token = srsCardSetFaceTokenScript(
      srsCardFaceMediaToken(cardId: 'c"1', showingAnswer: true),
    );
    expect(full, contains(token));
    expect(
      full.indexOf(token),
      lessThan(full.indexOf('__fushiSrsSetCard(')),
      reason: '标记先于换卡：页面上报时带回的是这一面',
    );
  });
}
