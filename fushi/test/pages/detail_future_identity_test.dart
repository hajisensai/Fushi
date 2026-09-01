import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/collection_detail_shared.dart';
import 'package:fushi/src/pages/implementations/collection_relations_section.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_work_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2010 守卫：详情页链路上的 `FutureBuilder.future` 必须有**稳定身份**。
///
/// 用户症状是「Fushi 一拉到前台就闪」。桌面端每次窗口激活都会走一遍
/// `AppLifecycleState.resumed` → 重取系统调色板 → 通知主题 → 整棵树重建。重建
/// 本身无害，害的是把 future 写在 `build()` 里：那样每次重建都是一个新 Future。
///
/// 后果分两档，**不要混为一谈**：
///
/// ① 判 `connectionState` 的（[VideoWorkDetailPage]）＝ 真的闪。换 future 后
///    FutureBuilder 走 `_snapshot.inState(ConnectionState.none)`，状态不再是
///    done → 整页落回加载指示器，子页 [MediaCollectionDetailPage] 从树上消失、
///    以全新 State 重建，它自己的 `_loading` 一并复位 → 剧集列表重查一遍。
/// ② 只读 `snap.data` 的（相关作品区、标签 chip 行）＝ **不闪**。上面那个
///    `inState` 保留 data，旧结果继续渲染。代价是每次重建都白查一次库。
///
/// 所以这里钉两条不同的不变式：①「重建后不许退回加载态、State 必须原地复用」，
/// ②「重建后不许再对库发查询」。
///
/// 变异有效性（已实测）：把任一处 future 改回 `build()` 里现取，对应用例即红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _SelectCounter counter;
  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    counter = _SelectCounter();
    db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(counter),
    );
    collectionId =
        await db.createMediaCollection('作品', collectionType: 'playlist');
  });

  tearDown(() => db.close());

  testWidgets(
    '作品资料页：祖先重建后子页 State 原地复用，不退回加载态',
    (WidgetTester tester) async {
      final _RebuildHarness harness = _RebuildHarness(
        builder: (BuildContext context) => VideoWorkDetailPage(
          database: db,
          repository: VideoBookRepository(db),
          workRef: VideoWorkRef.collection(collectionId),
          onChanged: () {},
        ),
      );
      await tester.pumpWidget(
        TranslationProvider(child: MaterialApp(home: harness)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MediaCollectionDetailPage), findsOneWidget);
      final State<StatefulWidget> before =
          tester.state(find.byType(MediaCollectionDetailPage));
      final int selectsBefore = counter.selects;

      // 模拟「主题通知 → 全树重建」：widget 换新实例，位置与类型不变。
      _RebuildHarness.of(tester).rebuild();
      // 只 pump 一帧、不 settle：闪就发生在这一帧里，settle 会把它重新加载完、
      // 把证据抹掉。
      await tester.pump();

      expect(
        find.byType(MediaCollectionDetailPage),
        findsOneWidget,
        reason: '退回 waiting 会让整个子页从树上消失 = 用户看到的那一下闪',
      );
      expect(
        identical(tester.state(find.byType(MediaCollectionDetailPage)), before),
        isTrue,
        reason: 'State 被换掉 = _loading 复位 + 剧集列表重查一遍',
      );
      expect(
        counter.selects,
        selectsBefore,
        reason: '纯重建不该产生任何新查询',
      );
    },
  );

  testWidgets(
    '相关作品区：祖先重建后不重查库',
    (WidgetTester tester) async {
      await db.replaceCollectionRelations(
        collectionId,
        <CollectionRelationsCompanion>[
          CollectionRelationsCompanion.insert(
            collectionId: collectionId,
            relationType: 'sequel',
            sortIndex: const Value<int>(0),
            targetCollectionId: const Value<int?>(null),
            source: 'bangumi',
            subjectId: '200',
            title: '某作品 第二季',
          ),
        ],
      );

      final _RebuildHarness harness = _RebuildHarness(
        builder: (BuildContext context) => SingleChildScrollView(
          child: CollectionRelationsSection(
            database: db,
            collectionId: collectionId,
            onOpenCollection: (int _) {},
            onDownload: (CollectionRelationRow _) {},
          ),
        ),
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: Scaffold(body: harness)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('某作品 第二季'), findsOneWidget);
      final int selectsBefore = counter.selects;

      _RebuildHarness.of(tester).rebuild();
      await tester.pump();

      expect(
        counter.selects,
        selectsBefore,
        reason: 'future 写在 build 里 = 每次重建都对 collection_relations 重查一遍',
      );
      // 数据仍在（drift 的 inState 保留 data，本区本来就不闪）。
      expect(find.text('某作品 第二季'), findsOneWidget);
    },
  );

  testWidgets(
    '标签 chip 行：祖先重建后不重查库',
    (WidgetTester tester) async {
      final MediaCollectionRow collection =
          (await db.getMediaCollectionById(collectionId))!;

      final _RebuildHarness harness = _RebuildHarness(
        builder: (BuildContext context) =>
            _TagChipsHost(db: db, collection: collection),
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: Scaffold(body: harness)),
        ),
      );
      await tester.pumpAndSettle();

      final int selectsBefore = counter.selects;

      _RebuildHarness.of(tester).rebuild();
      await tester.pump();

      expect(
        counter.selects,
        selectsBefore,
        reason: 'future 写在 build 里 = 每次重建都把本合集标签重查一遍',
      );
    },
  );
}

/// 数 `runSelect`，用来钉「纯重建不产生查询」。
///
/// 不按表名过滤：pumpAndSettle 之后这棵树已经静止，此后任何一条 select 都只能
/// 来自重建本身，正是要抓的东西。
class _SelectCounter extends QueryInterceptor {
  int selects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects++;
    return executor.runSelect(statement, args);
  }
}

/// 祖先重建 harness。
///
/// **必须经 builder 现造 child**，不能持有一个 child 实例直接返回：Flutter 对
/// `identical` 的 widget 会短路掉子树重建，那样这些用例会在有 bug 的代码上照样
/// 绿——测的就不是重建了。
class _RebuildHarness extends StatefulWidget {
  const _RebuildHarness({required this.builder});

  final WidgetBuilder builder;

  static _RebuildHarnessState of(WidgetTester tester) =>
      tester.state(find.byType(_RebuildHarness)) as _RebuildHarnessState;

  @override
  State<_RebuildHarness> createState() => _RebuildHarnessState();
}

class _RebuildHarnessState extends State<_RebuildHarness> {
  int _tick = 0;

  void rebuild() => setState(() => _tick++);

  @override
  Widget build(BuildContext context) {
    // _tick 只是让 build 的产物每次都是新实例。
    assert(_tick >= 0);
    return widget.builder(context);
  }
}

/// [CollectionDetailShared] 的最小宿主：mixin 的 chip 行离不开一个 State 宿主，
/// 但整个 [MediaCollectionDetailPage] 只在成员非空时才渲染 chip 行，太重。
class _TagChipsHost extends StatefulWidget {
  const _TagChipsHost({required this.db, required this.collection});

  final FushiDatabase db;
  final MediaCollectionRow collection;

  @override
  State<_TagChipsHost> createState() => _TagChipsHostState();
}

class _TagChipsHostState extends State<_TagChipsHost>
    with CollectionDetailShared<_TagChipsHost> {
  String _name = '';

  @override
  FushiDatabase get detailDatabase => widget.db;

  @override
  MediaCollectionRow get detailCollection => widget.collection;

  @override
  String get detailName => _name;

  @override
  set detailName(String value) => _name = value;

  @override
  VoidCallback get detailOnChanged => () {};

  @override
  Widget build(BuildContext context) => buildDetailTagChips();
}
