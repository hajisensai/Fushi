// 复习页与「不是它自己发起的」库变化对齐（同步拉入、操作目录 / AI 写入、模板编辑器等压在上面的页面），
// 以及 readSrsStore 不再把打开失败吞成「没就绪」、本机复习页登记活跃会话计数。
//
// 内存库 + 确定性假排程内核；widget 测试里没有 WebView，卡面换成纯文本实现并记下每次的 face。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

class _SilentAudio implements SrsCardAudioOutput {
  @override
  Future<String?> resolve(String name) => Future<String?>.value(name);

  @override
  Future<bool> playToEnd(String path) => Future<bool>.value(true);

  @override
  Future<void> stop() async {}
}

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

String _expressionField() => srsLapisFieldId(kSrsTestProfile, 'Expression');

Future<void> _addLapis(
  WidgetTester tester,
  SrsDbStore store,
  String expression,
) async {
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        _expressionField(): expression,
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'meaning',
      },
    ),
  );
}

/// 改 [cardId] 所在笔记的词条字段（库里直接写，不经复习页）。
Future<void> _setExpression(
  WidgetTester tester,
  SrsDbStore store,
  String cardId,
  String expression,
) async {
  await tester.runAsync(() async {
    final SrsCardDetail detail = (await store.cardDetail(cardId))!;
    await store.updateNote(
      detail.note.id,
      fieldsById: <String, String>{_expressionField(): expression},
    );
  });
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
  required Future<SrsDbStore?> Function() store,
  required List<SrsCardFace> faces,
  required String deckId,
}) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = SrsTestAppModel();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) => store()),
        srsCardAudioOutputProvider.overrideWithValue(_SilentAudio()),
        srsReviewChromeFloatingProvider.overrideWithValue(false),
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
          home: SrsReviewPage(deckId: deckId, deckName: 'Default'),
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

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SrsReviewPage)));

/// 同步拉入了变更（与 runtime 的 `bumpPulledRevision` 同一条路径）。
void _bumpPulled(WidgetTester tester) => SrsRevisionOrigin().bumpPulled(
  _container(tester).read(srsRevisionProvider.notifier),
);

/// 本机别处写入（操作目录 / AI、压在上面的页面）后发的信号。
void _bumpLocal(WidgetTester tester) =>
    _container(tester).read(srsRevisionProvider.notifier).state++;

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));
  final List<String> phases = <String>[];
  setUp(() {
    phases.clear();
    SrsReviewPage.debugPhase = phases.add;
  });
  tearDown(() => SrsReviewPage.debugPhase = null);

  int reloads() => phases.where((String p) => p == 'reloadCurrent').length;

  testWidgets('同步拉入改了当前卡的笔记：原地换成新内容，仍停在答案面', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    await _addLapis(tester, store, '飲む');
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(
      tester,
      store: () async => store,
      faces: faces,
      deckId: store.defaultDeckId,
    );
    final String current = faces.last.cardId;
    expect(current, isNotEmpty);
    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);
    expect(faces.last.showingAnswer, isTrue);

    await _setExpression(tester, store, current, '食べ物');
    _bumpPulled(tester);
    await _settle(tester);

    expect(faces.last.cardId, current, reason: '还是同一张卡');
    expect(faces.last.bodyHtml, contains('食べ物'), reason: '卡面按库里的新字段重画');
    expect(faces.last.showingAnswer, isTrue, reason: '外部变化不把答案面翻回去');
    expect(reloads(), 1);
    await _unmount(tester);
  });

  testWidgets('模板编辑器 / 操作目录改了笔记类型的 CSS（不写卡片缓存行）：当前卡按新样式重画', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(
      tester,
      store: () async => store,
      faces: faces,
      deckId: store.defaultDeckId,
    );
    expect(faces.last.cardId, isNotEmpty);
    expect(faces.last.css, isNot(contains('fushiExternalCss')));

    await tester.runAsync(() async {
      final SrsNoteTypeView type = (await store.noteType(
        store.lapisNoteTypeId,
      ))!;
      final bool wrote = await store.saveTemplateEdits(
        type.id,
        type.templates.first.id,
        css: '${type.css}\n.fushiExternalCss { color: red; }',
      );
      expect(wrote, isTrue);
    });
    _bumpLocal(tester);
    await _settle(tester);

    expect(faces.last.css, contains('fushiExternalCss'));
    expect(reloads(), 1);
    await _unmount(tester);
  });

  testWidgets('牌组改名（牌组设置类变化，不写卡片缓存行）：标题现读', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(
      tester,
      store: () async => store,
      faces: faces,
      deckId: store.defaultDeckId,
    );
    expect(find.text('Renamed elsewhere'), findsNothing);

    await tester.runAsync(
      () => store.editFields(
        SrsEntityKind.deck,
        store.defaultDeckId,
        <String, Object?>{SrsFieldKeys.name: 'Renamed elsewhere'},
      ),
    );
    _bumpPulled(tester);
    await _settle(tester);

    expect(find.text('Renamed elsewhere'), findsWidgets);
    expect(reloads(), 1);
    await _unmount(tester);
  });

  testWidgets('与当前卡无关的变化、本页自己的评分：不重读当前卡、不重建卡面', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    await _addLapis(tester, store, '飲む');
    await _addLapis(tester, store, '見る');
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(
      tester,
      store: () async => store,
      faces: faces,
      deckId: store.defaultDeckId,
    );
    final String current = faces.last.cardId;
    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);

    // 第三张笔记（既不是当前卡、也不是预取的下一张）被同步改了。
    final String unrelated = (await tester.runAsync(() async {
      final String next = (await store.nextCard(
        store.defaultDeckId,
        exclude: <String>{current},
      ))!;
      return (await store.nextCard(
        store.defaultDeckId,
        exclude: <String>{current, next},
      ))!;
    }))!;
    await _setExpression(tester, store, unrelated, '見物');
    final int built = faces.length;
    _bumpPulled(tester);
    await _settle(tester);
    expect(reloads(), 0, reason: '无关的变化不重读当前卡');
    expect(faces.length, built, reason: '无关的变化不重建卡面（不 setState）');
    expect(faces.last.showingAnswer, isTrue);

    // 本页自己的评分：只发 srsLocalWrite，换卡走 _loadNext，不额外重读。
    await tester.tap(find.byKey(const ValueKey<String>('srs-rate-3')));
    await _settle(tester);
    expect(faces.last.cardId, isNot(current));
    expect(faces.last.showingAnswer, isFalse);
    expect(reloads(), 0);
    await _unmount(tester);
  });

  testWidgets('预取好的下一张在评分前被改了笔记：评分后显示新内容，不拿旧预取上屏', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    await _addLapis(tester, store, '飲む');
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(
      tester,
      store: () async => store,
      faces: faces,
      deckId: store.defaultDeckId,
    );
    final String current = faces.last.cardId;
    final String? next = await tester.runAsync<String?>(
      () => store.nextCard(store.defaultDeckId, exclude: <String>{current}),
    );
    expect(next, isNotNull);
    // 不发修订号信号：只靠取用预取时的校验（笔记改了、卡片行逐列看不出来）。
    await _setExpression(tester, store, next!, '飲み物');

    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('srs-rate-3')));
    await _settle(tester);

    expect(faces.last.cardId, next, reason: '前提：评分后换到的正是预取的那张');
    expect(faces.last.bodyHtml, contains('飲み物'));
    await _unmount(tester);
  });

  testWidgets('本机复习页登记活跃会话计数，离开时撤销', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    final int before = srsActiveReviewSessions.value;
    await _pumpReview(
      tester,
      store: () async => store,
      faces: <SrsCardFace>[],
      deckId: store.defaultDeckId,
    );
    expect(srsActiveReviewSessions.value, before + 1);
    await _unmount(tester);
    expect(srsActiveReviewSessions.value, before);
  });

  const ValueKey<String> finishedKey = ValueKey<String>('srs-review-finished');
  const ValueKey<String> moreDueKey = ValueKey<String>('srs-review-more-due');

  testWidgets('复习完之后同步拉入了新卡：停在「复习完」页并出现入口，点入口回到复习', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(
      tester,
      store: () async => store,
      faces: faces,
      deckId: store.defaultDeckId,
    );
    expect(find.byKey(finishedKey), findsOneWidget);
    expect(find.byKey(moreDueKey), findsNothing);

    await _addLapis(tester, store, '食べる');
    _bumpPulled(tester);
    await _settle(tester);

    expect(find.byKey(finishedKey), findsOneWidget, reason: '不自动把卡塞到用户眼前');
    expect(faces, isEmpty);
    expect(find.byKey(moreDueKey), findsOneWidget, reason: '库里又有能出的卡：给入口');

    await tester.tap(find.byKey(moreDueKey));
    await _settle(tester);

    expect(find.byKey(finishedKey), findsNothing);
    expect(faces, isNotEmpty);
    expect(faces.last.cardId, isNotEmpty);
    await _unmount(tester);
  });

  testWidgets('复习完之后别处取消暂停：出现入口；又暂停回去：入口收起', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    final String card = (await tester.runAsync(
      () => store.cardIdsInDecks(<String>{store.defaultDeckId}),
    ))!.single;
    await tester.runAsync(() => store.setSuspended(card, true));
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(
      tester,
      store: () async => store,
      faces: faces,
      deckId: store.defaultDeckId,
    );
    expect(find.byKey(finishedKey), findsOneWidget);
    expect(find.byKey(moreDueKey), findsNothing);

    await tester.runAsync(() => store.setSuspended(card, false));
    _bumpLocal(tester);
    await _settle(tester);
    expect(find.byKey(moreDueKey), findsOneWidget);

    await tester.runAsync(() => store.setSuspended(card, true));
    _bumpLocal(tester);
    await _settle(tester);
    expect(find.byKey(finishedKey), findsOneWidget);
    expect(find.byKey(moreDueKey), findsNothing, reason: '入口跟着库走，没有能出的卡就不留');
    expect(faces, isEmpty);
    await _unmount(tester);
  });

  group('readSrsStore：打开失败原样抛出', () {
    testWidgets('复习页：打开失败显示真实错误（可重试），不报「排程内核不可用」', (WidgetTester tester) async {
      await _pumpReview(
        tester,
        store: () => Future<SrsDbStore?>.error(StateError('srs.db corrupt')),
        faces: <SrsCardFace>[],
        deckId: 'deck',
      );
      expect(find.textContaining('srs.db corrupt'), findsOneWidget);
      expect(find.text(t.srs_engine_unavailable), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('srs-review-load-retry')),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('readSrsStore / 操作目录：失败原样抛，null 只表示没有复习库', (
      WidgetTester tester,
    ) async {
      late WidgetRef failing;
      late WidgetRef absent;
      await tester.pumpWidget(
        Column(
          children: <Widget>[
            ProviderScope(
              overrides: <Override>[
                srsStoreProvider.overrideWith(
                  (Ref ref) => Future<SrsDbStore?>.error(StateError('boom')),
                ),
              ],
              child: Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? _) {
                  failing = ref;
                  return const SizedBox();
                },
              ),
            ),
            ProviderScope(
              overrides: <Override>[
                srsStoreProvider.overrideWith((Ref ref) async => null),
              ],
              child: Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? _) {
                  absent = ref;
                  return const SizedBox();
                },
              ),
            ),
          ],
        ),
      );
      Object? readError;
      Object? ctlError;
      bool absentRead = false;
      SrsDbStore? none;
      unawaited(
        readSrsStore(
          failing,
        ).then((_) {}, onError: (Object e) => readError = e),
      );
      unawaited(
        requireSrsCtlStore(
          SrsCtlDeps(
            store: () => readSrsStore(failing),
            moduleEnabled: () => true,
            changed: () {},
          ),
        ).then((_) {}, onError: (Object e) => ctlError = e),
      );
      unawaited(
        readSrsStore(absent).then((SrsDbStore? s) {
          none = s;
          absentRead = true;
        }),
      );
      await tester.pump();
      await tester.pump();

      expect(readError, isA<StateError>());
      expect(ctlError, isA<StateError>(), reason: '操作目录的失败结果是真实错误，不是「复习库还没就绪」');
      expect(ctlError, isNot(isA<CtlFailure>()));
      expect(absentRead, isTrue);
      expect(none, isNull);
    });
  });
}
