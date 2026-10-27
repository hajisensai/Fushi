import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_book_metadata_routes.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

import 'book_metadata_test_fixture.dart';

/// 书的元数据写回（`book.scrape.apply`）的撤销往返：经 `OpInvoker` 以模型身份执行，
/// 撤销载荷先过一遍 JSON（与持久化进 `ai_agent_actions` 后再撤销同一形态）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late BookMetaTestModel model;
  late OpCatalog catalog;
  late OpInvoker invoker;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_book_undo_');
    model = BookMetaTestModel(db, prefs, thumbs);
    MediaSource.setDatabase(db);
    bookMetadataFacadeFactory = () => BookMetadataScrapeFacade(
      scraper: offlineScraper(
        subjects: <String, Map<String, Object?>>{
          '21': bangumiSubject('21', 'Candidate', cn: '候选标题'),
        },
      ),
      downloadImage: fakeDownloader(thumbs),
    );
    final OpContext context = OpContext(ref: BookMetaRef(model));
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
  });

  tearDown(() async {
    bookMetadataFacadeFactory = BookMetadataScrapeFacade.new;
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  Future<OpInvocation> run(String id, Map<String, Object?> args) =>
      invoker.invoke(
        id,
        args,
        caller: OpCaller.model,
        captureUndo: true,
        grantedGates: <String>{
          for (final OpParam g in catalog[id]!.spec.gateParams) g.name,
        },
      );

  Future<OpUndoStatus> undo(OpInvocation invocation) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return (await catalog[invocation.op.id]!.undo!.revert(payload)).status;
  }

  Future<MediaItem> item(String key) async =>
      (await ReaderFushiSource.instance.mediaItemForBookKey(key))!;

  Future<BookMetadataState> state(String key) async =>
      BookMetadataScrapeFacade().currentState(
        appModel: model,
        item: await item(key),
      );

  File image(int seed) =>
      File('${thumbs.path}/manual_$seed.jpg')..writeAsBytesSync(fakeJpeg(seed));

  test('三条操作都有描述：两条 read、写回是可撤销的 write', () {
    expect(catalog['book.scrape.search']!.risk, OpRisk.read);
    expect(catalog['book.scrape.get']!.risk, OpRisk.read);
    expect(catalog['book.scrape.apply']!.risk, OpRisk.write);
    expect(catalog['book.scrape.apply']!.undo, isNotNull);
  });

  test('换封面 + 显示名 → 撤销：旧封面从备份拷回、显示名清除', () async {
    await seedBook(db, '猫');
    await BookMetadataScrapeFacade().applyToBook(
      appModel: model,
      item: await item('猫'),
      cover: image(1),
    );
    final BookMetadataState original = await state('猫');

    final OpInvocation applied = await run(
      'book.scrape.apply',
      <String, Object?>{
        'key': 'book:猫',
        'id': '21',
        'fields': <String>['cover', 'title'],
      },
    );
    final BookMetadataState after = await state('猫');
    expect(after.overrideTitle, '候选标题');
    expect(after.coverSha, isNot(original.coverSha));

    expect(await undo(applied), OpUndoStatus.done);
    final BookMetadataState restored = await state('猫');
    expect(restored.coverSha, original.coverSha);
    expect(restored.overrideTitle, isNull);
  });

  test('执行前没有 override 封面 → 撤销清除封面', () async {
    await seedBook(db, '犬');
    final OpInvocation applied = await run(
      'book.scrape.apply',
      <String, Object?>{'key': 'book:犬', 'id': '21'},
    );
    expect((await state('犬')).coverSha, isNotNull);
    expect(await undo(applied), OpUndoStatus.done);
    expect((await state('犬')).coverSha, isNull);
  });

  test('执行后用户又手动换了封面 → superseded，不覆盖', () async {
    await seedBook(db, '鸟');
    final OpInvocation applied = await run(
      'book.scrape.apply',
      <String, Object?>{'key': 'book:鸟', 'id': '21'},
    );
    await BookMetadataScrapeFacade().applyToBook(
      appModel: model,
      item: await item('鸟'),
      cover: image(9),
    );
    final String? manual = (await state('鸟')).coverSha;
    expect(await undo(applied), OpUndoStatus.superseded);
    expect((await state('鸟')).coverSha, manual);
  });

  test('只动了封面时，之后手动改名不算覆盖（只比这次动过的字段）', () async {
    await seedBook(db, '鱼');
    final OpInvocation applied = await run(
      'book.scrape.apply',
      <String, Object?>{'key': 'book:鱼', 'id': '21'},
    );
    await ReaderFushiSource.instance.setOverrideTitleFromMediaItem(
      item: await item('鱼'),
      title: '用户改的名',
    );
    expect(await undo(applied), OpUndoStatus.done);
    final BookMetadataState now = await state('鱼');
    expect(now.coverSha, isNull);
    expect(now.overrideTitle, '用户改的名');
  });
}
