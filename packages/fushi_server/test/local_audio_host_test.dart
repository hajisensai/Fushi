import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/models/local_audio_source_pref.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_audio_library_store.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 无头服务端托管本地音频库（BUG-2815）：以前 host 服务没接本地音频三件，
/// 清单恒空、推送传完才抛 UnsupportedError。现在服务端做存储中转——
/// 客户端 push → 落盘登记 → 另一台客户端 pull 拿到同一个包；delete 生效；
/// 重启后清单还在。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerPaths paths;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_localaudio_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    paths = ServerPaths(p.join(tmp.path, 'data'));
    await paths.ensureLayout();
  });

  tearDown(() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 起一个「进程」：新的偏好缓存（从 DB 预热）+ 新的 host，模拟重启。
  Future<({HeadlessHost host, LocalLibraryHostService svc})> boot() async {
    final ServerPrefs prefs = ServerPrefs(db);
    await prefs.warmUp();
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final HeadlessHost host = HeadlessHost(
      config: ServerConfig.defaults(dataDir: paths.dataDir),
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
    );
    return (host: host, svc: host.buildLibraryService());
  }

  /// 一份像样的 SQLite 文件字节（头 16 字节是 SQLite 魔数，其后是可辨认的内容）。
  Uint8List sqliteBytes(int seed) => Uint8List.fromList(<int>[
    ...'SQLite format 3'.codeUnits,
    0,
    for (int i = 0; i < 4096; i++) (i * 31 + seed) & 0xff,
  ]);

  /// 客户端侧：把一个本机音频库打成推送包（与 app 的 sync 上传同一个打包器）。
  Future<File> clientPackage({
    required String displayName,
    required Uint8List bytes,
    bool enabled = true,
    List<LocalAudioSourcePref> sources = const <LocalAudioSourcePref>[],
  }) async {
    final Directory dir = await Directory(
      p.join(tmp.path, 'client'),
    ).create(recursive: true);
    final File dbFile = File(p.join(dir.path, 'local_audio_1.db'))
      ..writeAsBytesSync(bytes);
    return SyncAssetPackageService(db: db).exportLocalAudioPackage(
      displayName: displayName,
      enabled: enabled,
      sources: sources,
      dbFile: dbFile,
      outputFile: File(p.join(dir.path, '$displayName.fushiaudiolib')),
    );
  }

  List<String> names(List<RemoteLocalAudioInfo> list) => <String>[
    for (final RemoteLocalAudioInfo a in list) a.displayName,
  ];

  test('push → 列出 → 另一台 pull 拿到同一个包（字节 / enabled / 子来源）', () async {
    final LocalLibraryHostService svc = (await boot()).svc;
    final Uint8List bytes = sqliteBytes(7);
    const List<LocalAudioSourcePref> sources = <LocalAudioSourcePref>[
      LocalAudioSourcePref(name: 'nhk16', enabled: true),
      LocalAudioSourcePref(name: 'jpod', enabled: false),
    ];

    await svc.importLocalAudio(
      await clientPackage(
        displayName: 'NHK',
        bytes: bytes,
        enabled: false,
        sources: sources,
      ),
    );

    // 同一个服务实例（互联启动时只构造一次）必须看见刚推来的库。
    expect(names(await svc.listLocalAudio()), <String>['NHK']);

    final File exported = await svc.exportLocalAudio('NHK');
    addTearDown(() => exported.parent.delete(recursive: true));
    final Directory pullStaging = await Directory(
      p.join(tmp.path, 'pull'),
    ).create();
    final LocalAudioPackageContents pulled = await SyncAssetPackageService(
      db: db,
    ).importLocalAudioPackage(packageFile: exported, stagingDir: pullStaging);
    expect(pulled.displayName, 'NHK');
    expect(pulled.enabled, isFalse);
    expect(
      <String>[
        for (final LocalAudioSourcePref s in pulled.sources)
          '${s.name}:${s.enabled}',
      ],
      <String>['nhk16:true', 'jpod:false'],
    );
    expect(pulled.dbFile.readAsBytesSync(), bytes);

    // 解包副本不在 staging 里堆积。
    expect(
      paths.temp.listSync().whereType<File>().where(
        (File f) => p.basename(f.path).endsWith('.db'),
      ),
      isEmpty,
    );
  });

  test('重启后清单还在；delete 摘登记并删库副本；重复推送不重复登记', () async {
    final LocalLibraryHostService first = (await boot()).svc;
    await first.importLocalAudio(
      await clientPackage(displayName: 'A', bytes: sqliteBytes(1)),
    );
    await first.importLocalAudio(
      await clientPackage(displayName: 'B', bytes: sqliteBytes(2)),
    );
    await first.importLocalAudio(
      await clientPackage(displayName: 'A', bytes: sqliteBytes(3)),
    );
    expect(names(await first.listLocalAudio()), <String>['A', 'B']);

    // 「重启」：新偏好缓存 + 新 host，登记来自 DB 的 preferences 表。
    final ({HeadlessHost host, LocalLibraryHostService svc}) second =
        await boot();
    expect(names(await second.svc.listLocalAudio()), <String>['A', 'B']);
    final String aPath = second.host.localAudio.entries.first.path;
    expect(p.isWithin(paths.support.path, aPath), isTrue);
    expect(
      File(aPath).readAsBytesSync(),
      sqliteBytes(1),
      reason: '重名推送按 displayName 跳过，不覆盖已有库',
    );

    await second.svc.deleteLocalAudio('A');
    expect(names(await second.svc.listLocalAudio()), <String>['B']);
    expect(File(aPath).existsSync(), isFalse);

    final LocalLibraryHostService third = (await boot()).svc;
    expect(names(await third.listLocalAudio()), <String>['B']);
  });

  test('登记格式与 app LocalAudioManager 同键同形', () async {
    final ({HeadlessHost host, LocalLibraryHostService svc}) booted =
        await boot();
    await booted.svc.importLocalAudio(
      await clientPackage(displayName: 'NHK', bytes: sqliteBytes(4)),
    );
    final Object? raw = booted.host.prefs.getPref(
      LocalAudioLibraryStore.entriesPrefKey,
    );
    expect(LocalAudioLibraryStore.entriesPrefKey, 'local_audio_dbs');
    expect(raw, isA<String>());
    expect(raw as String, contains('"displayName":"NHK"'));
    expect(
      p.basename(booted.host.localAudio.entries.single.path),
      matches(RegExp(r'^local_audio_\d+\.db$')),
    );
  });

  test('推来的不是 SQLite 库：拒绝且不登记', () async {
    final LocalLibraryHostService svc = (await boot()).svc;
    await expectLater(
      svc.importLocalAudio(
        await clientPackage(
          displayName: 'Junk',
          bytes: Uint8List.fromList(<int>[0x50, 0x4b, 3, 4, 0, 0]),
        ),
      ),
      throwsA(isA<InvalidLocalAudioPackageException>()),
    );
    expect(await svc.listLocalAudio(), isEmpty);
    expect(
      paths.support.listSync().where(
        (FileSystemEntity e) => p.basename(e.path).startsWith('local_audio_'),
      ),
      isEmpty,
    );
  });
}
