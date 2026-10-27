// 复习页用户反馈（#3 / #7 / #8 / #9 / #10 / #15 / #16 / #17）。
//
// - 页面层走真实路径：内存库 + 确定性假排程内核 → SrsReviewPage；整面卡面换成纯文本实现
//   （widget 测试里没有 WebView），原生 Fushi 卡面照常原生绘制；音频出口换成记录器。
// - 卡面链接脚本在 node 里真的执行（最小 DOM 桩，跑的是生产常量本身）。
// 数据库读写放 tester.runAsync。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FlutterView;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_card_video_channel.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show
        inlineVideoCoverHtml,
        inlineVideoSentenceAudioHtml,
        inlineVideoWordAudioHtml;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/node_runtime.dart';
import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<void> _addFushiCard(
  WidgetTester tester,
  SrsDbStore store,
  Map<String, String> fields,
) async {
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.fushiCardNoteTypeId,
      fieldsById: <String, String>{
        for (final MapEntry<String, String> e in fields.entries)
          srsFushiCardFieldId(kSrsTestProfile, e.key): e.value,
      },
    ),
  );
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 底栏重播键位置偏好钉在内存里（测试里偏好层没初始化）。
class _ReplayApp extends AppModel {
  _ReplayApp() : super(testPlatformServices());

  SrsReviewReplayButton replay = SrsReviewReplayButton.start;

  @override
  SrsReviewReplayButton get srsReviewReplayButton => replay;
}

/// 记录播放的音频出口；[missing] 里的名字解析不到（媒体库里没有）。
class _RecordingAudio implements SrsCardAudioOutput {
  _RecordingAudio({this.missing = const <String>{}});

  final Set<String> missing;
  final List<String> played = <String>[];

  @override
  Future<String?> resolve(String name) =>
      Future<String?>.value(missing.contains(name) ? null : name);

  @override
  Future<bool> playToEnd(String name) {
    played.add(name);
    return Future<bool>.value(true);
  }

  @override
  Future<void> stop() async {}
}

Future<void> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  AppModel? app,
  Size size = const Size(1200, 900),
  List<Override> overrides = const <Override>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = app ?? AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => null as SrsMediaStore?,
        ),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
        ...overrides,
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
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

bool _showingAnswer(WidgetTester tester) => tester
    .widget<SrsFushiCardView>(find.byType(SrsFushiCardView))
    .face
    .showingAnswer;

/// Windows 平台视图卡面的替身：自带 `autofocus` 焦点节点，指针按下即抢 Flutter 焦点
/// （同 flutter_inappwebview_windows 的 custom_platform_view.dart）。
class _PlatformViewLikeFace extends StatefulWidget {
  const _PlatformViewLikeFace({required this.face});

  final SrsCardFace face;

  @override
  State<_PlatformViewLikeFace> createState() => _PlatformViewLikeFaceState();
}

class _PlatformViewLikeFaceState extends State<_PlatformViewLikeFace> {
  final FocusNode _node = FocusNode(debugLabel: 'fake-platform-view');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    focusNode: _node,
    child: Listener(
      onPointerDown: (PointerDownEvent _) => _node.requestFocus(),
      child: SrsPlainCardFace(face: widget.face),
    ),
  );
}

/// 把段落写成 `*加粗*` 记号，便于断言强调落在哪。
String _marks(List<SrsInline> segs) =>
    segs.map((SrsInline x) => x.bold ? '*${x.text}*' : x.text).join();

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('#8 评分换卡后的键盘焦点', () {
    testWidgets('鼠标评分进下一张：焦点回本页、OS 焦点也被请求拉回，空格照样显示答案', (
      WidgetTester tester,
    ) async {
      final List<int> nativeRequests = <int>[];
      final void Function(FlutterView) original =
          SrsReviewPage.requestNativeViewFocus;
      SrsReviewPage.requestNativeViewFocus = (FlutterView view) =>
          nativeRequests.add(view.viewId);
      addTearDown(() => SrsReviewPage.requestNativeViewFocus = original);

      final SrsDbStore store = await _openStore(tester);
      for (final String w in <String>['区別', '飲む']) {
        await _addFushiCard(tester, store, <String, String>{
          'Expression': w,
          'MainDefinition': 'x',
          'Sentence': '<b>$w</b>です',
        });
      }
      await _pumpReview(tester, store: store);
      expect(_showingAnswer(tester), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _settle(tester);
      expect(_showingAnswer(tester), isTrue);

      nativeRequests.clear();
      await tester.tap(find.byKey(const ValueKey<String>('srs-rate-3')));
      await _settle(tester, rounds: 20);
      expect(_showingAnswer(tester), isFalse);
      expect(
        nativeRequests,
        isNotEmpty,
        reason: '换卡后要把 OS 焦点从 WebView2 拉回 FlutterView（Flutter 内挪节点不够）',
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'srs-review',
        reason: '换卡后键盘焦点落回复习页自己的节点',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _settle(tester);
      expect(_showingAnswer(tester), isTrue, reason: '评分后空格应翻面');
      await _unmount(tester);
    });
  });

  group('BUG-3859 纯键盘空格背卡：翻到答案面后空格 / 数字键仍生效', () {
    // 整面卡面换成「带 autofocus 焦点节点、按下即 requestFocus」的替身，模拟 Windows
    // 平台视图（custom_platform_view.dart 的 Focus(autofocus: true) + 指针按下抢焦）。
    Widget platformViewLikeFace(BuildContext context, SrsCardFace face) {
      return _PlatformViewLikeFace(face: face);
    }

    for (final bool native in <bool>[true, false]) {
      for (final String before in <String>[
        'none',
        'clickShowAnswer',
        'clickCard',
      ]) {
        testWidgets('native=$native before=$before：空格翻面→空格良好→空格翻面…', (
          WidgetTester tester,
        ) async {
          final SrsDbStore store = await _openStore(tester);
          for (final String w in <String>['区別', '飲む', '食べる', '読む']) {
            if (native) {
              await _addFushiCard(tester, store, <String, String>{
                'Expression': w,
                'MainDefinition': 'x',
                'Sentence': '<b>$w</b>です',
              });
            } else {
              await tester.runAsync(
                () => store.createNote(
                  noteTypeId: store.lapisNoteTypeId,
                  fieldsById: <String, String>{
                    srsLapisFieldId(kSrsTestProfile, 'Expression'): w,
                    srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'x',
                  },
                ),
              );
            }
          }
          await _pumpReview(
            tester,
            store: store,
            overrides: <Override>[
              srsCardFaceBuilderProvider.overrideWithValue(
                platformViewLikeFace,
              ),
            ],
          );
          final Finder rate3 = find.byKey(const ValueKey<String>('srs-rate-3'));
          bool answerShown() => rate3.evaluate().isNotEmpty;

          if (before == 'clickShowAnswer') {
            await tester.tap(
              find.byKey(const ValueKey<String>('srs-show-answer')),
            );
            await _settle(tester);
            expect(answerShown(), isTrue);
          } else if (before == 'clickCard') {
            final Rect card = tester.getRect(
              find.byKey(const ValueKey<String>('srs-card-surface')),
            );
            await tester.tapAt(card.bottomCenter - const Offset(0, 30));
            await _settle(tester);
            expect(answerShown(), isFalse);
          }

          // 3 张卡 × (翻面 + 评分)：每一下空格都必须生效，焦点始终在本页子树里。
          bool shown = answerShown();
          for (int i = 0; i < 6; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await _settle(tester, rounds: 20);
            shown = !shown;
            expect(
              answerShown(),
              shown,
              reason: '第 ${i + 1} 下空格应${shown ? '翻到答案面' : '评「良好」换到下一张问题面'}',
            );
            final FocusNode? primary = FocusManager.instance.primaryFocus;
            final FocusNode page = FocusManager.instance.rootScope.descendants
                .firstWhere((FocusNode n) => n.debugLabel == 'srs-review');
            expect(
              primary == page || page.descendants.contains(primary),
              isTrue,
              reason: '键盘焦点必须留在复习页子树里（实际：${primary?.debugLabel}）',
            );
          }
          // 答案面上数字键评分同样生效。
          if (!answerShown()) {
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await _settle(tester, rounds: 20);
          }
          expect(answerShown(), isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
          await _settle(tester, rounds: 20);
          expect(answerShown(), isFalse, reason: '答案面按 3 应评「良好」');
          await _unmount(tester);
        });
      }
    }
  });

  group('#17 底栏重播键单独一行、在评分按钮上方', () {
    testWidgets('靠左一行，翻面前后都在底栏按钮上方；评分按钮四颗等宽铺满', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addFushiCard(tester, store, <String, String>{
        'Expression': '区別',
        'MainDefinition': 'x',
        'ExpressionAudio': '[sound:w.mp3]',
        'Sentence': '<b>区別</b>がつかない',
        'SentenceAudio': '[sound:s.mp3]',
      });
      final _RecordingAudio audio = _RecordingAudio();
      await _pumpReview(
        tester,
        store: store,
        app: _ReplayApp(),
        overrides: <Override>[
          srsCardAudioOutputProvider.overrideWithValue(audio),
        ],
      );
      final Finder r0 = find.byKey(
        const ValueKey<String>('srs-bottom-replay-0'),
      );
      final Finder r1 = find.byKey(
        const ValueKey<String>('srs-bottom-replay-1'),
      );
      final Finder show = find.byKey(const ValueKey<String>('srs-show-answer'));
      expect(r0, findsOneWidget);
      expect(r1, findsOneWidget);
      expect(
        tester.getRect(r0).bottom,
        lessThanOrEqualTo(tester.getRect(show).top),
      );
      await tester.tap(show);
      await _settle(tester);
      final Rect rate1 = tester.getRect(
        find.byKey(const ValueKey<String>('srs-rate-1')),
      );
      final Rect rate4 = tester.getRect(
        find.byKey(const ValueKey<String>('srs-rate-4')),
      );
      expect(tester.getRect(r1).bottom, lessThanOrEqualTo(rate1.top));
      expect(
        tester.getRect(r0).left,
        moreOrLessEquals(rate1.left, epsilon: 0.5),
      );
      expect(tester.getSize(r0).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(r0).height,
        lessThan(rate1.height),
        reason: '辅助操作比评分按钮小一号',
      );
      expect(rate4.width, moreOrLessEquals(rate1.width, epsilon: 0.5));
      await _unmount(tester);
    });
  });

  group('#15 底栏重播键只按卡面实际画出的音频', () {
    testWidgets('释义里的词典音频、重复引用、媒体库缺的文件都不出键，自动播放也跳过', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _addFushiCard(tester, store, <String, String>{
        'Expression': '～というほどではない',
        // 释义里带着词典自己的发音（多段）：不是卡面上的发音键。
        'MainDefinition':
            '例文[sound:d1.mp3][sound:d2.mp3]<audio src="d3.mp3"></audio>',
        'ExpressionAudio': '[sound:w.mp3][sound:w.mp3][sound:gone.mp3]',
        'Sentence': '言うほどではない',
        'SentenceAudio': '[sound:s.mp3]',
      });
      final _RecordingAudio audio = _RecordingAudio(
        missing: <String>{'gone.mp3'},
      );
      await _pumpReview(
        tester,
        store: store,
        app: _ReplayApp(),
        overrides: <Override>[
          srsCardAudioOutputProvider.overrideWithValue(audio),
        ],
      );
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      expect(audio.played, <String>[
        'w.mp3',
        's.mp3',
      ], reason: '翻面自动播放：单词一次、例句一次，跳过缺失与释义里的音频');
      expect(
        find.byKey(const ValueKey<String>('srs-bottom-replay-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-bottom-replay-2')),
        findsNothing,
        reason: '只有单词、例句两颗',
      );
      await _unmount(tester);
    });
  });

  group('#10 视频片段与例句发音键联动、同一时刻只出一路声音', () {
    testWidgets('同步片段卡：例句键播的是片段（经同一个序列），不再另起一路纯音频', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _addFushiCard(tester, store, <String, String>{
        'Expression': 'くっつく',
        'MainDefinition': 'stick',
        'Picture': inlineVideoCoverHtml('clip.webm'),
        'ExpressionAudio': inlineVideoWordAudioHtml('w.mp3'),
        'Sentence': 'コトネちゃんに <b>くっつこう</b>',
        'SentenceAudio': inlineVideoSentenceAudioHtml('clip.webm'),
      });
      final _RecordingAudio audio = _RecordingAudio();
      await _pumpReview(
        tester,
        store: store,
        app: _ReplayApp(),
        overrides: <Override>[
          srsCardAudioOutputProvider.overrideWithValue(audio),
        ],
      );
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      expect(audio.played, <String>['w.mp3', 'clip.webm']);
      audio.played.clear();
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-fushi-sentence-audio')),
      );
      await _settle(tester);
      expect(audio.played, <String>['clip.webm']);
      // 底栏：单词、片段两颗（例句音频与片段是同一个文件，不重复出键）。
      expect(
        find.byKey(const ValueKey<String>('srs-bottom-replay-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-bottom-replay-2')),
        findsNothing,
      );
      await _unmount(tester);
    });
  });

  group('原生卡面媒体清单（srsFushiCardMedia）', () {
    test('片段自带例句：例句单元 = 片段，无陪播音频', () {
      final SrsFushiCardMedia m = srsFushiCardMedia(<String, String>{
        'Picture': inlineVideoCoverHtml('clip.webm'),
        'SentenceAudio': inlineVideoSentenceAudioHtml('clip.webm'),
        'ExpressionAudio': inlineVideoWordAudioHtml('w.mp3'),
      }, audioCardFront: false);
      expect(m.clipCarriesSentence, isTrue);
      expect(m.back, <String>['w.mp3', 'clip.webm']);
      expect(m.companionSentence, isEmpty);
      expect(m.front, isEmpty);
    });

    test('例句音频是另一个文件：片段只陪播画面，不单独进序列', () {
      final SrsFushiCardMedia m = srsFushiCardMedia(<String, String>{
        'Picture': inlineVideoCoverHtml('clip.webm'),
        'SentenceAudio': '[sound:s.mp3]',
      }, audioCardFront: false);
      expect(m.clipCarriesSentence, isFalse);
      expect(m.back, <String>['s.mp3']);
      expect(m.companionSentence, <String>['s.mp3']);
    });

    test('听力卡正面：有例句音频播例句，否则播单词', () {
      expect(
        srsFushiCardMedia(<String, String>{
          'SentenceAudio': '[sound:s.mp3]',
          'ExpressionAudio': '[sound:w.mp3]',
        }, audioCardFront: true).front,
        <String>['s.mp3'],
      );
      expect(
        srsFushiCardMedia(<String, String>{
          'ExpressionAudio': '[sound:w.mp3]',
        }, audioCardFront: true).front,
        <String>['w.mp3'],
      );
    });

    test('选段结果去重（模板复制多份同一音频不再连播 / 多出键）', () {
      expect(
        srsReplaySounds(
          questionHtml: '[sound:a.mp3][sound:a.mp3]',
          answerHtml: '[sound:a.mp3][sound:a.mp3][sound:b.mp3][sound:b.mp3]',
          answerSide: true,
          includeQuestion: true,
        ),
        <String>['a.mp3', 'b.mp3'],
      );
    });
  });

  group('序列跳过缺失的媒体', () {
    test('中间一段解析不到：跳过它接着播后面的', () async {
      final _RecordingAudio out = _RecordingAudio(missing: <String>{'b'});
      await SrsCardAudioSequencer(out).play(<String>['a', 'b', 'c']);
      expect(out.played, <String>['a', 'c']);
    });
  });

  group('片段通道：例句陪播与同一时刻只出一路声音', () {
    test('例句陪播音频开播时：先停在播的片段，再让画面从头陪播', () async {
      final SrsCardVideoChannel channel = SrsCardVideoChannel(
        buildPending: () => false,
      );
      final _FakeClip clip = _FakeClip();
      final _FakeCompanion companion = _FakeCompanion();
      channel
        ..attach('clip.webm', clip)
        ..attachCompanion(companion)
        ..setSentenceAudio(Object(), <String>['s.mp3']);
      final List<String> audio = <String>[];
      await channel.playToEndOrElse('s.mp3', () async {
        audio.add('s.mp3');
        return true;
      });
      expect(audio, <String>['s.mp3']);
      expect(clip.stops, 1, reason: '片段不能和例句音频同时出声');
      expect(companion.started, <String>['s.mp3']);
      // 不是例句音频（单词）：不陪播。
      await channel.playToEndOrElse('w.mp3', () async => true);
      expect(companion.started, <String>['s.mp3']);
    });

    test('走片段时停掉共用音频播放器里还在响的上一段', () async {
      final SrsCardVideoChannel channel = SrsCardVideoChannel(
        buildPending: () => false,
      );
      final _FakeClip clip = _FakeClip();
      channel.attach('clip.webm', clip);
      int audioStops = 0;
      final bool done = await channel.playToEndOrElse(
        'clip.webm',
        () async => fail('片段挂着时不走纯音频'),
        stopAudio: () async => audioStops++,
      );
      expect(done, isTrue);
      expect(clip.plays, 1);
      expect(audioStops, 1);
    });

    test('声明者卸载只清自己那份', () {
      final SrsCardVideoChannel channel = SrsCardVideoChannel();
      final Object a = Object(), b = Object();
      channel
        ..setSentenceAudio(a, <String>['x'])
        ..setSentenceAudio(b, <String>['y'])
        ..clearSentenceAudio(a);
      expect(channel.isSentenceAudio('y'), isTrue);
      channel.clearSentenceAudio(b);
      expect(channel.isSentenceAudio('y'), isFalse);
    });
  });

  group('#9 例句目标词强调', () {
    test('例句已有 <b>：原样', () {
      final List<SrsInline> segs = srsParseInline('言う<b>ほど</b>に');
      expect(srsEmphasizeSentenceTarget(segs, terms: <String>['区別']), segs);
    });

    test('没有 <b>：按词条写法逐字找到', () {
      expect(
        _marks(
          srsEmphasizeSentenceTarget(
            srsParseInline('言うほどに 区別がつかないです'),
            terms: <String>['区別'],
          ),
        ),
        '言うほどに *区別*がつかないです',
      );
    });

    test('活用形：くっつく → くっつこう；言う → 言った', () {
      expect(
        _marks(
          srsEmphasizeSentenceTarget(
            srsParseInline('コトネちゃんに くっつこう'),
            terms: <String>['くっつく'],
          ),
        ),
        'コトネちゃんに *くっつこう*',
      );
      expect(
        _marks(
          srsEmphasizeSentenceTarget(
            srsParseInline('彼はそう言った。'),
            terms: <String>['言う', 'いう'],
          ),
        ),
        '彼はそう*言った*。',
      );
    });

    test('句子里写成片假名：平 / 片假名视为同一字', () {
      expect(
        _marks(
          srsEmphasizeSentenceTarget(
            srsParseInline('もうクッツイタ'),
            terms: <String>['くっつく'],
          ),
        ),
        'もう*クッツイタ*',
      );
    });

    test('SentenceFurigana 没带 <b>：用 Sentence 字段里标出的目标词定位（注音段整段强调）', () {
      final List<SrsInline> segs = srsEmphasizeSentenceTarget(
        srsParseInline('図書館[としょかん]に 通[かよ]っている'),
        marked: srsMarkedTargets('図書館に<b>通って</b>いる'),
      );
      expect(
        segs.where((SrsInline x) => x.bold).map((SrsInline x) => x.text),
        <String>['通', 'って'],
      );
      expect(segs.firstWhere((SrsInline x) => x.text == '通').ruby, 'かよ');
    });

    test('挖空 {{c1::…}}：显示答案并强调', () {
      expect(
        _marks(srsParseInline(srsClozeToBold('彼は{{c1::区別::くべつ}}がない'))),
        '彼は*区別*がない',
      );
      expect(srsMarkedTargets('彼は{{c1::区別}}がない'), <String>['区別']);
    });

    test('找不到：不乱标', () {
      final List<SrsInline> segs = srsParseInline('まったく関係ない文');
      expect(srsEmphasizeSentenceTarget(segs, terms: <String>['区別']), segs);
    });

    testWidgets('卡面：例句字段没 <b> 时目标词照样用强调色', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addFushiCard(tester, store, <String, String>{
        'Expression': 'くっつく',
        'MainDefinition': 'stick',
        'Sentence': 'コトネちゃんに くっつこう',
      });
      await _pumpReview(tester, store: store);
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      final SrsRubyText sentence = tester.widget<SrsRubyText>(
        find.byKey(const ValueKey<String>('srs-fushi-sentence')),
      );
      expect(_marks(sentence.segments), 'コトネちゃんに *くっつこう*');
      expect(sentence.emphasis, isNotNull);
      await _unmount(tester);
    });
  });

  group('#3 卡面页面自己发起的播放缺省不放行', () {
    test('SrsCardFace.autoplayMedia 缺省 false（只有复习页按牌组开关显式打开）', () {
      final SrsCardFace face = SrsCardFace(
        cardId: 'c',
        showingAnswer: true,
        bodyHtml: '',
        css: '',
        languageCode: null,
        onBridgeKey: (_) {},
      );
      expect(face.autoplayMedia, isFalse);
      expect(face.withLayout(SrsCardLayout.wide).autoplayMedia, isFalse);
    });
  });

  group('#16 卡面链接', () {
    test('桥参数解析', () {
      expect(
        SrsCardLinkAction.parse(<String, Object?>{
          'kind': 'external',
          'href': 'https://example.com',
        }),
        isA<SrsCardExternalLink>(),
      );
      final SrsCardLinkAction? lookup =
          SrsCardLinkAction.parse(<String, Object?>{
            'kind': 'lookup',
            'query': ' よほど ',
            'x': 10,
            'y': 20,
            'width': 30,
            'height': 12,
          });
      expect(lookup, isA<SrsCardLookupLink>());
      expect((lookup! as SrsCardLookupLink).query, 'よほど');
      expect(
        (lookup as SrsCardLookupLink).rect,
        const Rect.fromLTWH(10, 20, 30, 12),
      );
      expect(SrsCardLinkAction.parse('x'), isNull);
      expect(
        SrsCardLinkAction.parse(<String, Object?>{'kind': 'lookup'}),
        isNull,
      );
    });

    final NodeTestRuntime node = NodeTestRuntime.probe();
    test(
      '链接脚本（node）：外链交浏览器、?query= / entry:// 查词（剥振假名）、sound: 忽略、锚点放行',
      skip: node.skipReason,
      () async {
        const String js =
            '''
const assert = require('node:assert/strict');
globalThis.window = globalThis;
const calls = [];
window.flutter_inappwebview = { callHandler: (n, a) => calls.push([n, a]) };
let listener = null;
globalThis.document = {
  addEventListener(type, fn, capture){
    assert.equal(type, 'click'); assert.equal(capture, true); listener = fn;
  },
};
globalThis.URLSearchParams = URLSearchParams;
function text(t){ return { nodeType: 3, textContent: t }; }
function el(tag, kids, cls){
  return { nodeType: 1, tagName: tag, childNodes: kids || [],
    classList: { contains: c => (cls || []).indexOf(c) >= 0 } };
}
function anchor(href, kids){
  const a = el('A', kids);
  a.getAttribute = () => href;
  a.getBoundingClientRect = () => ({ left: 1, top: 2, width: 3, height: 4 });
  return a;
}
function click(a){
  let prevented = false;
  listener({ target: { closest: () => a }, preventDefault(){ prevented = true; } });
  return prevented;
}
$kSrsCardLinkScript
assert.ok(click(anchor('https://example.com/x', [text('site')])));
assert.ok(click(anchor('?query=%E3%82%88%E3%81%BB%E3%81%A9&wildcards=off', [text('➡ よほど')])));
assert.ok(click(anchor('entry://足が棒', [el('RUBY', [text('足'), el('RT', [text('あし')])]), text('が棒')])));
assert.ok(click(anchor('sound://a.mp3', [text('♪')])));
assert.equal(click(anchor('#top', [text('top')])), false, '页内锚点放行');
assert.ok(click(anchor('fushi://source?x=1', [text('src')])));
assert.deepEqual(calls, [
  ['onSrsCardLink', { kind: 'external', href: 'https://example.com/x' }],
  ['onSrsCardLink', { kind: 'lookup', query: 'よほど', x: 1, y: 2, width: 3, height: 4 }],
  ['onSrsCardLink', { kind: 'lookup', query: '足が棒', x: 1, y: 2, width: 3, height: 4 }],
  ['onSrsSourceLink', 'fushi://source?x=1'],
]);
''';
        final Directory dir = Directory.systemTemp.createTempSync('srs-link-');
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
  });
}

class _FakeClip implements SrsCardVideoHandle {
  int plays = 0;
  int stops = 0;

  @override
  Future<bool> playFromStart() {
    plays++;
    return Future<bool>.value(true);
  }

  @override
  Future<void> stop() async => stops++;
}

class _FakeCompanion implements SrsCardSentenceCompanion {
  final List<String> started = <String>[];

  @override
  void sentenceStarted(String name) => started.add(name);
}
