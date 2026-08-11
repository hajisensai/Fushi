import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-1502（改名跨端 LWW）+ BUG-1503（push 方向带显示名）。
///
/// BUG-1488 把「书的改名」打通成了单向、一次性的：显示名能从 host 下发到 peer，
/// 但两处封死——
///  1. `preferences` 只有 key/value 两列，合并端无从判断「谁更新」，只能
///     insert-if-absent，母设备**第二次**改名传不到已有 override 的子设备；
///  2. 反方向（本端 push 书给 host）是裸 .epub 上传、无任何元数据，改名不跟随。
///
/// 修法：v84 给 `preferences` 加 `updated_at`（LWW 比较键，存量行戳 0 =「时刻
/// 未知」），三条通道（互联清单下发 / 下载后采纳 / 备份合并）统一成同一条裁决
/// 规则「严格更新才写、平局保留本机、本机无该行则采纳」；push 方向按视频推送的
/// `X-Hibiki-Video-Title` 先例加两个 additive header 把显示名 + 戳带上去。
///
/// 变异实测（2026-08-11，逐条破坏 lib 确认转红后**反向替换**还原，零 lib 残留）：
///  - `database_prefs_media.part.dart` 的 `setPrefIfNewer` 判据
///    `existing.updatedAt >= updatedAt` 改成 `existing.updatedAt > updatedAt`
///    → 「平局保留本机」两例转红（旧对端把本机改名覆盖掉）；
///  - 同函数 `updatedAt: Value<int>(updatedAt)` 改成写 `now`
///    → 「戳落成对端的戳」转红；
///  - `app_model_library_host_service.dart` 的 `displayTitleAt:
///    overrideTitles[r.bookKey]?.updatedAt ?? 0` 改成恒 `0`
///    → 「host 清单下发改名时刻」转红；
///  - `fushi_library_host_service.dart` wire 键 `'displayTitleAt'` 改名成
///    `'displayTitleAtX'` → 「戳过 wire 往返」转红；
///  - `interconnect_sync_backend.dart` 的 `putRemoteBook` 两个 `req.headers.set`
///    整段删掉 → 「push 带 header」两例转红；
///  - `backup_merge_engine.dart` `_mergeOverrideTitlePrefs` 的第二条 UPDATE 语句
///    删掉 → 「合并导入：母设备更新的改名覆盖子设备旧改名」转红。
void main() {
  /// 该书改名偏好在 `preferences` 表里的**完整落库 key**（持久化编码，逐字节钉死）。
  String overridePrefKey(String bookKey) =>
      'src:reader_fushi:override_title://fushi://book/$bookKey';

  EpubBooksCompanion book(String bookKey, String title) =>
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '/fake/$bookKey.epub',
        extractDir: '/fake/$bookKey',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
      );

  Future<FushiDatabase> openDb(String prefix) async {
    final Directory dir = await Directory.systemTemp.createTemp(prefix);
    addTearDown(() => cleanupTempDir(dir));
    final FushiDatabase db = FushiDatabase(dir.path);
    addTearDown(db.close);
    return db;
  }

  AppModelLibraryHostService buildHost(
    FushiDatabase db, {
    Future<String?> Function(File)? importBookFromFile,
  }) =>
      AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        importBookFromFile: importBookFromFile,
      );

  /// 把 [db] 装成 `MediaSource` 的共享库并清掉源的内存偏好缓存，让
  /// `ReaderFushiSource.instance`（单例，跨用例复用）每次都从这个库读。
  Future<ReaderFushiSource> bindSource(FushiDatabase db) async {
    MediaSource.setDatabase(db);
    final ReaderFushiSource source = ReaderFushiSource.instance;
    await source.refreshPreferencesFromDb();
    return source;
  }

  // ── A. wire DTO：戳是 additive 的，旧 host 缺键回落 0 ─────────────────────

  test('改过名且有戳 → wire 带 displayTitleAt；戳过 wire 往返不变', () {
    const RemoteBookInfo renamed = RemoteBookInfo(
      title: '原始书名',
      hasContent: true,
      displayTitle: '我改的名字',
      displayTitleAt: 1700000000000,
    );
    expect(renamed.toJson()['displayTitleAt'], 1700000000000);

    final RemoteBookInfo decoded =
        RemoteBookInfo.fromJson(renamed.toJson().cast<String, Object?>());
    expect(decoded.displayTitle, '我改的名字');
    expect(decoded.displayTitleAt, 1700000000000);
    // 身份红线：显示名与戳都不参与任何键派生。
    expect(decoded.downloadId, '原始书名');
  });

  test('没改过名 / 戳为 0：不写 displayTitleAt 键（旧 client 字节不变）', () {
    const RemoteBookInfo plain =
        RemoteBookInfo(title: '原始书名', hasContent: true);
    expect(plain.toJson().containsKey('displayTitleAt'), isFalse);

    // 改过名但戳 0（v84 迁移前改的存量）→ 发名字不发戳。
    const RemoteBookInfo stampless = RemoteBookInfo(
      title: '原始书名',
      hasContent: true,
      displayTitle: '我改的名字',
    );
    expect(stampless.toJson()['displayTitle'], '我改的名字');
    expect(stampless.toJson().containsKey('displayTitleAt'), isFalse);
  });

  test('旧 host（只发 displayTitle 不发戳）：displayTitleAt 回落 0', () {
    final RemoteBookInfo decoded = RemoteBookInfo.fromJson(<String, Object?>{
      'title': '原始书名',
      'hasContent': true,
      'displayTitle': '旧 host 上改的名',
    });
    expect(decoded.displayName, '旧 host 上改的名');
    expect(decoded.displayTitleAt, 0, reason: '缺戳 = 时刻未知 = LWW 平局输给本机');
  });

  // ── B. host 清单：把本机 override 的戳一并下发 ──────────────────────────

  test('host 清单下发改名时刻（peer 才能做 LWW）', () async {
    final FushiDatabase db = await openDb('bug1502_host_');
    await db.insertEpubBook(book('原始书名', '原始书名'));
    await db.setPrefIfNewer(
      overridePrefKey('原始书名'),
      PrefCodec.encode('我改的名字'),
      updatedAt: 1700000000000,
    );

    final List<RemoteBookInfo> books = await buildHost(db).listBooks();
    expect(books.single.displayTitle, '我改的名字');
    expect(books.single.displayTitleAt, 1700000000000);
  });

  test('host 上 v84 前改的名（戳 0）照常下发名字，戳为 0', () async {
    final FushiDatabase db = await openDb('bug1502_host_legacy_');
    await db.insertEpubBook(book('原始书名', '原始书名'));
    await db.customStatement(
      'INSERT INTO preferences ("key", "value", "updated_at") VALUES (?, ?, 0)',
      <Object?>[overridePrefKey('原始书名'), PrefCodec.encode('存量改名')],
    );

    final List<RemoteBookInfo> books = await buildHost(db).listBooks();
    expect(books.single.displayTitle, '存量改名');
    expect(books.single.displayTitleAt, 0);
  });

  // ── C. peer 采纳：母设备第二次改名终于能落地 ────────────────────────────

  test('母设备改名两次 → 已有本机 override 的子设备最终显示最新那个', () async {
    final FushiDatabase db = await openDb('bug1502_adopt_');
    final ReaderFushiSource source = await bindSource(db);
    await db.insertEpubBook(book('书甲', '书甲'));

    // 子设备自己先改过名（本地写 → 戳 now）。
    await source.setOverrideTitleFromMediaItem(
      item: source.overrideTitleMediaItemForBookKey('书甲'),
      title: '子设备自己起的名',
    );
    final int localAt = (await db.getPrefUpdatedAt(overridePrefKey('书甲')))!;

    // 母设备第一次改名，比本机旧 → 不覆盖（本机改名优先，与旧行为一致）。
    expect(
      await source.adoptOverrideTitleIfNewer(
        item: source.overrideTitleMediaItemForBookKey('书甲'),
        title: '母设备第一次',
        updatedAt: localAt - 1000,
      ),
      isFalse,
    );
    expect(source.overrideTitleForBookKey('书甲'), '子设备自己起的名');

    // 母设备第二次改名，晚于本机 → 覆盖。**这正是 BUG-1488 修不了的那一步。**
    expect(
      await source.adoptOverrideTitleIfNewer(
        item: source.overrideTitleMediaItemForBookKey('书甲'),
        title: '母设备第二次',
        updatedAt: localAt + 1000,
      ),
      isTrue,
    );
    expect(source.overrideTitleForBookKey('书甲'), '母设备第二次',
        reason: '内存缓存必须与 DB 一起走，否则书架会一直显示旧名');
    expect(
      PrefCodec.decodeUntyped((await db.getAllPrefs())[overridePrefKey('书甲')]!),
      '母设备第二次',
    );
    // 戳落成对端的戳，不是 now——否则本机永远最新，母设备的第三次改名再也进不来。
    expect(await db.getPrefUpdatedAt(overridePrefKey('书甲')), localAt + 1000);
  });

  test('戳相等：保留本机（确定性平局规则）', () async {
    final FushiDatabase db = await openDb('bug1502_tie_');
    final ReaderFushiSource source = await bindSource(db);
    await db.insertEpubBook(book('书甲', '书甲'));
    await source.setOverrideTitleFromMediaItem(
      item: source.overrideTitleMediaItemForBookKey('书甲'),
      title: '本机的名',
    );
    final int localAt = (await db.getPrefUpdatedAt(overridePrefKey('书甲')))!;

    expect(
      await source.adoptOverrideTitleIfNewer(
        item: source.overrideTitleMediaItemForBookKey('书甲'),
        title: '同戳对端的名',
        updatedAt: localAt,
      ),
      isFalse,
    );
    expect(source.overrideTitleForBookKey('书甲'), '本机的名');
  });

  test('旧对端（无戳 → 0）：本机改过名就不覆盖，本机没改过就采纳', () async {
    final FushiDatabase db = await openDb('bug1502_oldpeer_');
    final ReaderFushiSource source = await bindSource(db);
    await db.insertEpubBook(book('书甲', '书甲'));
    await db.insertEpubBook(book('书乙', '书乙'));

    await source.setOverrideTitleFromMediaItem(
      item: source.overrideTitleMediaItemForBookKey('书甲'),
      title: '本机的名',
    );

    // 书甲：本机改过 → 旧对端不得覆盖（降级语义：无戳者输）。
    expect(
      await source.adoptOverrideTitleIfNewer(
        item: source.overrideTitleMediaItemForBookKey('书甲'),
        title: '旧对端的名',
        updatedAt: 0,
      ),
      isFalse,
    );
    expect(source.overrideTitleForBookKey('书甲'), '本机的名');

    // 书乙：本机没改过 → 照常采纳（BUG-1488 已有能力不能退化）。
    expect(
      await source.adoptOverrideTitleIfNewer(
        item: source.overrideTitleMediaItemForBookKey('书乙'),
        title: '旧对端的名',
        updatedAt: 0,
      ),
      isTrue,
    );
    expect(source.overrideTitleForBookKey('书乙'), '旧对端的名');
  });

  // ── D. 备份合并：与另两条通道同一裁决 ────────────────────────────────────

  test('合并导入 LWW：更新的覆盖、更旧的不覆盖、平局保留本机', () async {
    final Directory srcDir =
        await Directory.systemTemp.createTemp('bug1502_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final FushiDatabase src = FushiDatabase(srcDir.path);
    for (final String key in <String>['书甲', '书乙', '书丙', '书丁']) {
      await src.insertEpubBook(book(key, key));
    }
    // 甲：src 更新 → 应覆盖。乙：src 更旧 → 不覆盖。丙：平局 → 保留本机。
    // 丁：本机没有 → 采纳。
    await src.setPrefIfNewer(overridePrefKey('书甲'), PrefCodec.encode('母设备较新'),
        updatedAt: 2000);
    await src.setPrefIfNewer(overridePrefKey('书乙'), PrefCodec.encode('母设备较旧'),
        updatedAt: 1000);
    await src.setPrefIfNewer(overridePrefKey('书丙'), PrefCodec.encode('母设备同戳'),
        updatedAt: 1500);
    await src.setPrefIfNewer(overridePrefKey('书丁'), PrefCodec.encode('母设备独有'),
        updatedAt: 1234);
    await src.close();

    final FushiDatabase target = await openDb('bug1502_dst_');
    for (final String key in <String>['书甲', '书乙', '书丙', '书丁']) {
      await target.insertEpubBook(book(key, key));
    }
    await target.setPrefIfNewer(
        overridePrefKey('书甲'), PrefCodec.encode('子设备较旧'),
        updatedAt: 1000);
    await target.setPrefIfNewer(
        overridePrefKey('书乙'), PrefCodec.encode('子设备较新'),
        updatedAt: 2000);
    await target.setPrefIfNewer(
        overridePrefKey('书丙'), PrefCodec.encode('子设备同戳'),
        updatedAt: 1500);

    final String srcDbPath =
        p.join(srcDir.path, 'fushi.db').replaceAll(r'\', '/');
    await target.customStatement("ATTACH DATABASE '$srcDbPath' AS mergesrc");
    await BackupMergeEngine(target).merge();
    await target.customStatement('DETACH DATABASE mergesrc');

    final Map<String, String> prefs = await target.getAllPrefs();
    String nameOf(String key) =>
        PrefCodec.decodeUntyped(prefs[overridePrefKey(key)]!) as String;

    expect(nameOf('书甲'), '母设备较新', reason: '母设备的第二次改名必须并进来（本 bug 的核心）');
    expect(await target.getPrefUpdatedAt(overridePrefKey('书甲')), 2000,
        reason: '戳也要跟着走，否则下一轮合并的比较基准是错的');
    expect(nameOf('书乙'), '子设备较新', reason: '更旧的备份不得回滚本机改名');
    expect(nameOf('书丙'), '子设备同戳', reason: '平局保留本机');
    expect(nameOf('书丁'), '母设备独有', reason: 'insert-if-absent 能力不能退化');
  });

  // ── E. push 方向（BUG-1503）：本端把书推给 host ─────────────────────────

  test('push：改过名 → 两个 additive header 随裸 .epub 上传', () async {
    final Map<String, String> seen = <String, String>{};
    final HttpServer server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest req) async {
      req.headers.forEach((String name, List<String> values) {
        seen[name.toLowerCase()] = values.first;
      });
      await req.drain<void>();
      req.response.statusCode = 200;
      await req.response.close();
    });

    final FushiDatabase db = await openDb('bug1503_push_');
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken('tok');
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String u, String t) async => true);
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);

    final Directory work = await Directory.systemTemp.createTemp('bug1503_f_');
    addTearDown(() => cleanupTempDir(work));
    final File epub = File(p.join(work.path, 'x.epub'));
    await epub.writeAsBytes(utf8.encode('EPUB'));

    await backend.putRemoteBook(
      '原始書名',
      epub,
      displayTitle: '本機改的名',
      displayTitleAt: 1700000000000,
    );

    // header 只收 ASCII：日文显示名必须 encodeComponent（裸写会抛）。
    expect(
      seen[kBookDisplayTitleHeader.toLowerCase()],
      Uri.encodeComponent('本機改的名'),
    );
    expect(seen[kBookDisplayTitleAtHeader.toLowerCase()], '1700000000000');
  });

  test('push：没改过名 → 一个 header 都不发（旧 host 字节不变）', () async {
    final Set<String> seen = <String>{};
    final HttpServer server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest req) async {
      req.headers.forEach((String name, List<String> values) {
        seen.add(name.toLowerCase());
      });
      await req.drain<void>();
      req.response.statusCode = 200;
      await req.response.close();
    });

    final FushiDatabase db = await openDb('bug1503_push_plain_');
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken('tok');
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String u, String t) async => true);
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);

    final Directory work = await Directory.systemTemp.createTemp('bug1503_g_');
    addTearDown(() => cleanupTempDir(work));
    final File epub = File(p.join(work.path, 'y.epub'));
    await epub.writeAsBytes(utf8.encode('EPUB'));

    await backend.putRemoteBook('原始書名', epub);
    expect(seen.contains(kBookDisplayTitleHeader.toLowerCase()), isFalse);
    expect(seen.contains(kBookDisplayTitleAtHeader.toLowerCase()), isFalse);

    // 显示名与 raw title 相同也不发（与 wire DTO 的 additive 判据同律）。
    await backend.putRemoteBook('原始書名', epub, displayTitle: '原始書名');
    expect(seen.contains(kBookDisplayTitleHeader.toLowerCase()), isFalse);
  });

  test('host 收到 push：显示名落成本机 override，身份仍由 importer 决定', () async {
    final FushiDatabase db = await openDb('bug1503_host_');
    final ReaderFushiSource source = await bindSource(db);

    // fake importer：落库并返回**真实** bookKey（重名会带后缀，与 title 不同）。
    final AppModelLibraryHostService host = buildHost(
      db,
      importBookFromFile: (File f) async {
        const String bookKey = '原始書名 (2)';
        await db.insertEpubBook(book(bookKey, bookKey));
        return bookKey;
      },
    );

    final Directory work = await Directory.systemTemp.createTemp('bug1503_h_');
    addTearDown(() => cleanupTempDir(work));
    final File epub = File(p.join(work.path, '原始書名.epub'));
    await epub.writeAsBytes(utf8.encode('EPUB'));

    await host.importBook(
      epub,
      displayTitle: '推送方改的名',
      displayTitleAt: 1700000000000,
    );

    // override 挂在 importer 返回的真实 bookKey 上，不是 URL 里的 title。
    expect(source.overrideTitleForBookKey('原始書名 (2)'), '推送方改的名');
    expect(
        await db.getPrefUpdatedAt(overridePrefKey('原始書名 (2)')), 1700000000000);
    // 身份红线：显示名没有变成书的 title / bookKey。
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows.single.title, '原始書名 (2)');
    expect(rows.single.bookKey, '原始書名 (2)');
  });

  test('host 收到旧 client 的 push（无 header）：行为与本轮之前逐字相同', () async {
    final FushiDatabase db = await openDb('bug1503_host_old_');
    final ReaderFushiSource source = await bindSource(db);
    final AppModelLibraryHostService host = buildHost(
      db,
      importBookFromFile: (File f) async {
        await db.insertEpubBook(book('書', '書'));
        return '書';
      },
    );

    final Directory work = await Directory.systemTemp.createTemp('bug1503_i_');
    addTearDown(() => cleanupTempDir(work));
    final File epub = File(p.join(work.path, '書.epub'));
    await epub.writeAsBytes(utf8.encode('EPUB'));

    await host.importBook(epub);

    expect(source.overrideTitleForBookKey('書'), isNull);
    expect((await db.getAllPrefs())[overridePrefKey('書')], isNull);
  });
}
