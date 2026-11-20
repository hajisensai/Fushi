/// 拍板 pr3481：本地音频库的内容身份（`local_audio_content_id.dart`）与服务端登记
/// 表（[LocalAudioLibraryStore]）按内容去重。
///
/// 起因：跨设备同步原本只按 displayName 做 union，PR #3481 改了新导入库的默认名
/// 之后，同一份库在新旧设备上名字不同，会被两边各拉一份。身份改认内容之后：
/// - 同一份库换了文件名 / 显示名、被绑定期补了索引，身份不变；
/// - 内容不同的库，名字相同也是两份；
/// - 服务端登记时同一份库不登记第二份，撞名的另起名，旧重复启动时收掉。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/models/local_audio_content_id.dart';
import 'package:fushi_engine/models/local_audio_db_entry.dart';
import 'package:fushi_engine/models/local_audio_source_pref.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_audio_library_store.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// 写一个 Yomitan 本地音频库（entries + android），每个 [words] 一行。
void writeAudioDb(String path, List<String> words, {String source = 'nhk16'}) {
  final File f = File(path);
  if (f.existsSync()) f.deleteSync();
  f.parent.createSync(recursive: true);
  final Database db = sqlite3.open(path);
  try {
    db.execute(
      'CREATE TABLE entries (expression TEXT, reading TEXT, file TEXT, '
      'source TEXT)',
    );
    db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    final PreparedStatement e = db.prepare(
      'INSERT INTO entries VALUES (?, ?, ?, ?)',
    );
    final PreparedStatement a = db.prepare(
      'INSERT INTO android VALUES (?, ?, ?)',
    );
    for (final String w in words) {
      e.execute(<Object?>[w, w, '$w.mp3', source]);
      a.execute(<Object?>[
        '$w.mp3',
        source,
        Uint8List.fromList(<int>[1, 2, 3]),
      ]);
    }
    e.close();
    a.close();
  } finally {
    db.dispose();
  }
}

class _MemPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

void main() {
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('la_identity_'));
  tearDown(() {
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  group('computeLocalAudioContentId', () {
    test('同一份内容换文件名、换行序、补索引后身份不变', () {
      final String a = p.join(work.path, 'android.db');
      final String b = p.join(work.path, 'local_audio_1.db');
      writeAudioDb(a, <String>['猫', '犬', '鳥']);
      writeAudioDb(b, <String>['鳥', '猫', '犬']);
      final String? idA = computeLocalAudioContentId(a);
      expect(isLocalAudioContentId(idA), isTrue, reason: '$idA');
      expect(computeLocalAudioContentId(b), idA, reason: '行序不同仍是同一份库');

      // 绑定期 LocalAudioDb.ensureIndexes 会往库文件里补索引：字节变了，身份不能变。
      final Database db = sqlite3.open(b);
      db.execute(
        'CREATE INDEX idx_entries_expr_read ON entries(expression, reading)',
      );
      db.dispose();
      expect(computeLocalAudioContentId(b), idA);
    });

    test('内容不同身份不同；不是音频库 / 不存在返回 null', () {
      final String a = p.join(work.path, 'a.db');
      final String b = p.join(work.path, 'b.db');
      writeAudioDb(a, <String>['猫']);
      writeAudioDb(b, <String>['犬']);
      expect(
        computeLocalAudioContentId(a),
        isNot(computeLocalAudioContentId(b)),
      );
      final String c = p.join(work.path, 'c.db');
      writeAudioDb(c, <String>['猫'], source: 'forvo');
      expect(
        computeLocalAudioContentId(c),
        isNot(computeLocalAudioContentId(a)),
        reason: '同词不同子来源也是不同的库',
      );

      final File junk = File(p.join(work.path, 'junk.db'))
        ..writeAsStringSync('not sqlite');
      expect(computeLocalAudioContentId(junk.path), isNull);
      expect(computeLocalAudioContentId(p.join(work.path, 'none.db')), isNull);
    });

    test('后台计算带缓存；resolve 优先用登记里存的身份', () async {
      final String a = p.join(work.path, 'a.db');
      writeAudioDb(a, <String>['猫']);
      expect(cachedLocalAudioContentId(a), isNull);
      final String? id = await computeLocalAudioContentIdInBackground(a);
      expect(id, computeLocalAudioContentId(a));
      expect(cachedLocalAudioContentId(a), id);

      const String stored = 'la1-0123456789abcdef0123456789abcdef';
      expect(
        await resolveLocalAudioContentId(
          LocalAudioDbEntry(path: a, displayName: 'x', contentId: stored),
        ),
        stored,
      );
      expect(
        await resolveLocalAudioContentId(
          LocalAudioDbEntry(path: a, displayName: 'x', contentId: 'garbage'),
        ),
        id,
        reason: '格式不对的身份不认，现算',
      );
    });
  });

  test('isSameLocalAudioLibrary：两边都有身份只比身份，缺一边才比名字', () {
    const String x = 'la1-00000000000000000000000000000001';
    const String y = 'la1-00000000000000000000000000000002';
    expect(
      isSameLocalAudioLibrary(
        nameA: 'android.db',
        contentIdA: x,
        nameB: 'Japanese audio',
        contentIdB: x,
      ),
      isTrue,
    );
    expect(
      isSameLocalAudioLibrary(
        nameA: 'NHK',
        contentIdA: x,
        nameB: 'NHK',
        contentIdB: y,
      ),
      isFalse,
    );
    expect(
      isSameLocalAudioLibrary(
        nameA: 'NHK',
        contentIdA: x,
        nameB: 'NHK',
        contentIdB: null,
      ),
      isTrue,
    );
    expect(
      isSameLocalAudioLibrary(
        nameA: 'NHK',
        contentIdA: null,
        nameB: 'Other',
        contentIdB: x,
      ),
      isFalse,
    );
    expect(uniqueLocalAudioDisplayName('NHK', <String>['A']), 'NHK');
    expect(
      uniqueLocalAudioDisplayName('NHK', <String>['NHK', 'NHK (2)']),
      'NHK (3)',
    );
  });

  test('LocalAudioDbEntry / RemoteLocalAudioInfo 的 contentId 往返，缺省不出键', () {
    const String x = 'la1-00000000000000000000000000000001';
    final LocalAudioDbEntry e = LocalAudioDbEntry.fromJson(
      const LocalAudioDbEntry(
        path: '/a',
        displayName: 'A',
        contentId: x,
      ).toJson(),
    );
    expect(e.contentId, x);
    expect(
      const LocalAudioDbEntry(path: '/a', displayName: 'A').toJson(),
      isNot(contains('contentId')),
    );
    final RemoteLocalAudioInfo r = RemoteLocalAudioInfo.fromJson(
      const RemoteLocalAudioInfo(displayName: 'A', contentId: x).toJson(),
    );
    expect(r.contentId, x);
    expect(r.key, x, reason: '新 host 给了身份，单项端点就用身份');
    expect(
      RemoteLocalAudioInfo.fromJson(<String, Object?>{
        'displayName': 'A',
        'contentId': '../evil',
      }).key,
      'A',
      reason: '格式不对的身份丢弃，退回按名',
    );
    expect(interconnectHostReportsLocalAudioContentId(null), isFalse);
    expect(
      interconnectHostReportsLocalAudioContentId(<String, Object?>{
        'liveLibrary': <String, Object?>{
          kLiveLibraryLocalAudioContentIdCapability: true,
        },
      }),
      isTrue,
    );
  });

  test('本地音频包 manifest 带身份；旧包没有时导入端对解出的库现算', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final SyncAssetPackageService packages = SyncAssetPackageService(db: db);
    final String dbPath = p.join(work.path, 'android.db');
    writeAudioDb(dbPath, <String>['猫', '犬']);
    final File pkg = File(p.join(work.path, 'out.fushiaudiolib'));
    await packages.exportLocalAudioPackage(
      displayName: 'android.db',
      enabled: true,
      sources: const <LocalAudioSourcePref>[],
      dbFile: File(dbPath),
      outputFile: pkg,
    );
    final Directory staging = Directory(p.join(work.path, 'staging'))
      ..createSync();
    final LocalAudioPackageContents c = await packages.importLocalAudioPackage(
      packageFile: pkg,
      stagingDir: staging,
    );
    expect(c.contentId, computeLocalAudioContentId(dbPath));
  });

  group('LocalAudioLibraryStore（服务端登记）按内容去重', () {
    late _MemPrefs prefs;
    late Directory libDir;
    late Directory staging;
    late LocalAudioLibraryStore store;

    setUp(() {
      prefs = _MemPrefs();
      libDir = Directory(p.join(work.path, 'lib'))..createSync();
      staging = Directory(p.join(work.path, 'staging'))..createSync();
      store = LocalAudioLibraryStore(prefs: prefs, databaseDirectory: libDir);
    });

    LocalAudioPackageContents staged(String name, List<String> words) {
      final String path = p.join(staging.path, '${name.hashCode}.db');
      writeAudioDb(path, words);
      return LocalAudioPackageContents(
        dbFile: File(path),
        displayName: name,
        enabled: true,
        sources: const <LocalAudioSourcePref>[],
      );
    }

    test('同一份库换了名字不登记第二份；撞名的不同库另起名登记', () async {
      expect(
        await store.importPackage(staged('Japanese audio', <String>['猫'])),
        isTrue,
      );
      expect(
        await store.importPackage(staged('android.db', <String>['猫'])),
        isFalse,
        reason: '内容相同，名字不同也是同一份库',
      );
      expect(
        await store.importPackage(staged('Japanese audio', <String>['犬'])),
        isTrue,
        reason: '名字相同内容不同是另一份库，不能被挡住',
      );
      expect(
        store.entries.map((LocalAudioDbEntry e) => e.displayName).toList(),
        <String>['Japanese audio', 'Japanese audio (2)'],
      );
      expect(
        store.entries.every(
          (LocalAudioDbEntry e) => isLocalAudioContentId(e.contentId),
        ),
        isTrue,
        reason: '登记时就写入身份',
      );
    });

    test('启动整理：给旧登记补身份，收掉内容相同的重复并删内部副本', () async {
      final String first = p.join(libDir.path, 'local_audio_1.db');
      final String dup = p.join(libDir.path, 'local_audio_2.db');
      final String other = p.join(libDir.path, 'local_audio_3.db');
      writeAudioDb(first, <String>['猫']);
      writeAudioDb(dup, <String>['猫']);
      writeAudioDb(other, <String>['犬']);
      await prefs.setPref(
        LocalAudioLibraryStore.entriesPrefKey,
        '[{"path":"$first","displayName":"android.db","enabled":true},'
                '{"path":"$dup","displayName":"Japanese audio","enabled":true},'
                '{"path":"$other","displayName":"English audio","enabled":true}]'
            .replaceAll(r'\', r'\\'),
      );

      expect(await store.normalizeContentIdentities(), 1);
      expect(
        store.entries.map((LocalAudioDbEntry e) => e.displayName).toList(),
        <String>['android.db', 'English audio'],
      );
      expect(File(dup).existsSync(), isFalse, reason: '重复的内部副本删掉');
      expect(File(first).existsSync(), isTrue);
      expect(
        store.entries.every(
          (LocalAudioDbEntry e) => isLocalAudioContentId(e.contentId),
        ),
        isTrue,
      );
      expect(await store.normalizeContentIdentities(), 0, reason: '幂等');
    });
  });
}
