// BUG-4948：冲突中心的人读名整页一次批量取，不按条读。
// 以前 _load 对每条冲突各调一次 cardDetail / note（每条三次读 + 字段寄存器物化）：6950 条冲突的库上一次
// 整页重读 2 万次读、63 s，常驻内存翻倍到 3.3 GB，停在本页时进程意外退出（反馈 9Z86HZWTxT）。
// 这里核对：① store.sortLabelsOf 读数固定、名字与笔记第一个字段（去标签）一致；② 页面读数不随冲突条数增长。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_conflicts_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_reads.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

Future<T> _io<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _syncAll(
  List<SrsDbStore> stores,
  SrsMemoryLocationStore location,
) async {
  for (int r = 0; r < 2; r++) {
    for (final SrsDbStore s in stores) {
      await srsSync2Round(
        host: s,
        location: location,
        locationId: 'test',
        nowMs: () => s.now().$1,
      );
    }
  }
}

/// [n] 条笔记各自被 A 删除、被 B 离线修改：B 这边有 [n] 条扣住的删除。返回 (库, A, B, 笔记 ID)。
Future<(List<FushiDatabase>, SrsDbStore, SrsDbStore, List<String>)> _heldEnv(
  int n,
) async {
  final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
    deviceId: 'a',
  );
  final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
    deviceId: 'b',
  );
  final SrsMemoryLocationStore location = SrsMemoryLocationStore();
  final List<String> notes = <String>[
    for (int i = 0; i < n; i++)
      await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '<b>魚$i</b>',
        },
      ),
  ];
  await _syncAll(<SrsDbStore>[a, b], location);
  for (final String id in notes) {
    await a.deleteNote(id);
    await b.updateNote(
      id,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Sentence'): '離線編集',
      },
    );
  }
  await _syncAll(<SrsDbStore>[a, b], location);
  return (<FushiDatabase>[dbA, dbB], a, b, notes);
}

Future<void> _pump(WidgetTester tester, SrsDbStore store) async {
  tester.view.physicalSize = const Size(1100, 8000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
        srsStoreProvider.overrideWith((Ref ref) async => store),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: const SrsConflictsPage(),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// 打开冲突页、等到 [n] 条扣住的删除都画出来，返回期间发出的读命令数。
Future<int> _pageReads(WidgetTester tester, int n) async {
  final (List<FushiDatabase> dbs, SrsDbStore _, SrsDbStore b, List<String> _) =
      await _io(tester, () => _heldEnv(n));
  final List<Map<String, Object?>> held = await _io(tester, b.sync2Conflicts);
  expect(held, hasLength(n));
  final int before = srsDebugReadCommands;
  await _pump(tester, b);
  for (int i = 0; i < 200; i++) {
    if (find
        .byKey(ValueKey<String>('srs-held-${held.last['id']}'))
        .evaluate()
        .isNotEmpty) {
      break;
    }
    await _settle(tester, rounds: 2);
  }
  final int reads = srsDebugReadCommands - before;
  for (final Map<String, Object?> c in held) {
    final Finder card = find.byKey(ValueKey<String>('srs-held-${c['id']}'));
    expect(card, findsOneWidget);
    // 名字按笔记第一个字段（去标签）认，不是 ID。
    expect(
      find.descendant(of: card, matching: find.textContaining('魚')),
      findsWidgets,
    );
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  await _io(tester, () async {
    for (final FushiDatabase db in dbs) {
      await db.close();
    }
  });
  return reads;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('sortLabelsOf：卡 / 笔记的名字取笔记第一个字段（去标签），两条批量读、不随条数增长', () async {
    final (FushiDatabase db, SrsDbStore s) = await openSrsTestStore();
    addTearDown(db.close);
    final List<String> notes = <String>[
      for (int i = 0; i < 12; i++)
        await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(kSrsTestProfile, 'Expression'): ' <i>猫$i</i> ',
          },
        ),
    ];
    final List<String> cards = <String>[
      for (final String id in notes) (await s.cardsOfNote(id)).first.id,
    ];
    final int before = srsDebugReadCommands;
    final ({Map<String, String> cards, Map<String, String> notes}) labels =
        await s.sortLabelsOf(
          cardIds: <String>[...cards, 'no-such-card'],
          noteIds: <String>[...notes, 'no-such-note'],
        );
    expect(srsDebugReadCommands - before, 2);
    for (int i = 0; i < notes.length; i++) {
      expect(labels.notes[notes[i]], '猫$i');
      expect(labels.cards[cards[i]], '猫$i');
    }
    expect(labels.notes.containsKey('no-such-note'), isFalse);
    expect(labels.cards.containsKey('no-such-card'), isFalse);

    final int none = srsDebugReadCommands;
    final ({Map<String, String> cards, Map<String, String> notes}) empty =
        await s.sortLabelsOf();
    expect(srsDebugReadCommands - none, 0);
    expect(empty.cards, isEmpty);
    expect(empty.notes, isEmpty);
  });

  testWidgets('冲突页读数不随扣住的删除条数增长（以前每条一次 note 物化）', (WidgetTester tester) async {
    final int few = await _pageReads(tester, 1);
    final int many = await _pageReads(tester, 12);
    // 旧代码每多一条冲突至少多 2 次读（entities + edits），12 条比 1 条多 ≥ 22 次。
    expect(many - few, lessThan(5), reason: '1 条冲突 $few 次读，12 条冲突 $many 次读');
  });
}
