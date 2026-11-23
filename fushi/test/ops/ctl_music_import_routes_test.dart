import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_disc.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_ripper.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/disc/music_disc_import.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_audio_intake_port.dart';
import 'package:fushi/src/media/music/music_online_sources.dart'
    show musicPluginSourceKey;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_music_import_routes.dart';
import 'package:fushi/src/ops/ctl_music_routes.dart' show kMusicCtlRoot;
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_music_import.dart';

import '../helpers/test_platform_services.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  bool moduleEnabled(ModuleId module) => true;
}

class _Ref implements WidgetRef {
  _Ref(this.model);

  final AppModel model;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

MusicPluginPackageInfo _package(String id, {String digest = 'd-1'}) =>
    MusicPluginPackageInfo(
      manifest: MusicPluginManifest(
        id: id,
        name: 'Plugin $id',
        version: '1.0.0',
        api: 1,
        capabilities: const <String>['lyricsSearch', 'lyricsFetch'],
        searchTypes: const <String>[],
        permissions: const <String>['network'],
        networkDomains: const <String>['example.com'],
      ),
      digest: digest,
      signer: null,
      files: const <String>['main.js'],
    );

/// 插件管理器假件：记下装 / 启停 / 卸载，不碰原生插件运行时。
class _FakePlugins implements MusicPluginManager {
  final Map<String, bool> enabled = <String, bool>{};
  final List<String> installedDigests = <String>[];
  String inspectDigest = 'd-1';

  @override
  Future<List<InstalledMusicPlugin>> listInstalled() async =>
      <InstalledMusicPlugin>[
        for (final MapEntry<String, bool> e in enabled.entries)
          InstalledMusicPlugin(
            id: e.key,
            enabled: e.value,
            info: _package(e.key),
          ),
      ];

  @override
  Future<MusicPluginPackageInfo> inspect(Uint8List zip) async {
    if (utf8.decode(zip) == 'bad') throw MusicPluginException('坏包');
    return _package('lyr', digest: inspectDigest);
  }

  @override
  Future<bool> signerChanged(MusicPluginPackageInfo info) async => false;

  @override
  Future<MusicPluginPackageInfo> install(Uint8List zip, String digest) async {
    installedDigests.add(digest);
    enabled['lyr'] = true;
    return _package('lyr', digest: digest);
  }

  @override
  Future<void> setEnabled(String id, bool on) async => enabled[id] = on;

  @override
  Future<void> uninstall(String id) async => enabled.remove(id);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late FushiDatabase db;
  late List<CtlRoute> routes;
  late List<List<String>> importedBatches;
  late _FakePlugins plugins;
  late bool pluginsAvailable;
  late List<(String, String, bool)> lyricExports;
  late Map<String, MusicDiscInfo> discs;
  late MusicAudioCdJobs cdJobs;
  late List<String> rippedImports;
  late String discDir;
  late PreferencesRepository prefs;

  MusicDiscInfo discInfo(String root) {
    final String ifo = p.join(root, 'VIDEO_TS', 'VIDEO_TS.IFO');
    File(ifo)
      ..createSync(recursive: true)
      ..writeAsStringSync('ifo');
    MusicDiscTitle title(int n, int chapters, {bool main = false}) =>
        MusicDiscTitle(
          titlePath: '$root/VIDEO_TS/title_$n',
          number: n,
          label: 'Title $n',
          duration: Duration(minutes: chapters * 4),
          chapters: <MusicDiscChapter>[
            for (int i = 0; i < chapters; i++)
              MusicDiscChapter(
                number: i + 1,
                start: Duration(minutes: i * 4),
                end: Duration(minutes: (i + 1) * 4),
              ),
          ],
          isMainFeature: main,
        );
    return MusicDiscInfo(
      kind: MusicDiscKind.dvd,
      rootPath: root,
      name: 'Live DVD',
      discId: 'disc-id-${p.basename(root)}',
      titles: <MusicDiscTitle>[title(1, 3, main: true), title(2, 2)],
      identityFilePath: ifo,
    );
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('music_import_ctl_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    importedBatches = <List<String>>[];
    plugins = _FakePlugins();
    pluginsAvailable = true;
    lyricExports = <(String, String, bool)>[];
    discDir = p.join(tmp.path, 'live');
    discs = <String, MusicDiscInfo>{discDir: discInfo(discDir)};
    cdJobs = MusicAudioCdJobs();
    rippedImports = <String>[];
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    routes = buildMusicImportCtlRoutesFor(
      MusicImportCtlDeps(
        database: () => db,
        musicEnabled: () => true,
        intakeAudioFiles: (FushiDatabase d, List<String> paths) async {
          importedBatches.add(paths);
          return MusicAudioIntakeResult(
            importedFiles: <String>[
              for (final String path in paths)
                if (path.endsWith('.flac')) path,
            ],
            skippedPaths: <String>[
              for (final String path in paths)
                if (!path.endsWith('.flac')) path,
            ],
          );
        },
        discService: (FushiDatabase d) => MusicDiscImportService(
          d,
          reader: (String path) async => discs[path],
          now: () => 1000,
        ),
        discCandidates: (String path) async =>
            discs.containsKey(path) ? <String>[path] : const <String>[],
        plugins: () => pluginsAvailable ? plugins : null,
        prefs: () => prefs,
        exportLyrics:
            (MusicLyricsTrackRef track, String format, bool overwrite) async {
              if (track.trackUid == 'no-lyrics') return null;
              final String out = p.setExtension(track.path, '.$format');
              if (!overwrite && File(out).existsSync()) {
                throw FileSystemException('lyrics file already exists', out);
              }
              lyricExports.add((track.trackUid, format, overwrite));
              File(out).writeAsStringSync('lyrics');
              return out;
            },
        audioCd: MusicCtlAudioCd(
          layoutOf: (String dir) =>
              dir.endsWith('cd') ? AudioCdLayout.windowsCda : null,
          canRip: (AudioCdLayout layout, String dir) => !dir.endsWith('nocd'),
          rip:
              (
                String dir,
                AudioCdLayout layout,
                AudioCdRipCancellation cancellation,
                void Function(AudioCdRipProgress) onProgress,
              ) async {
                onProgress((trackIndex: 0, trackCount: 2, fraction: 0.5));
                await Future<void>.delayed(Duration.zero);
                if (cancellation.isCancelled) return null;
                return p.join(tmp.path, 'ripped');
              },
          importRipped: (FushiDatabase d, String directory) async {
            rippedImports.add(directory);
            return 2;
          },
        ),
        clock: () => 4242,
      ),
      audioCdJobs: cdJobs,
    );
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, String> params = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    final CtlRoute route = routes.singleWhere(
      (CtlRoute r) => r.method == method && r.pattern == pattern,
    );
    String path = pattern;
    params.forEach((String k, String v) => path = path.replaceAll(':$k', v));
    return route.handler(
      CtlCall(method: method, path: path, params: params, body: body),
    );
  }

  Map<String, Object?> asMap(Object? v) => (v! as Map).cast<String, Object?>();

  Future<void> addTrack(String uid, String path) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: path,
          title: 'Song $uid',
          addedAt: 1,
          fileMtimeAt: 1,
          fileSize: 1,
        ),
      );

  test('路由都在 /api/admin/music 下、method + pattern 唯一', () {
    final Set<String> keys = <String>{};
    for (final CtlRoute r in routes) {
      expect(r.pattern, startsWith('$kMusicCtlRoot/'));
      expect(keys.add('${r.method} ${r.pattern}'), isTrue);
    }
  });

  group('导入音频文件', () {
    test('绝对路径交给导入入口，结构化返回导入 / 跳过', () async {
      final String song = p.join(tmp.path, 'a.flac');
      final String doc = p.join(tmp.path, 'b.txt');
      final Map<String, Object?> r = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/import',
          body: <String, Object?>{
            'paths': <String>[song, doc],
          },
        ),
      );
      expect(importedBatches.single, <String>[song, doc]);
      expect(r['imported'], <String>[song]);
      expect(r['skipped'], <String>[doc]);
      expect(r.containsKey('ok'), isFalse);
    });

    test('空列表 / 相对路径 400', () async {
      expect(() => call('POST', '$kMusicCtlRoot/import'), _status(400));
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/import',
          body: <String, Object?>{
            'paths': <String>['a.flac'],
          },
        ),
        _status(400),
      );
      expect(importedBatches, isEmpty);
    });
  });

  group('光盘', () {
    test('登记 → 列出 → 读 title → 章节导入（默认正片）→ 移除', () async {
      final Map<String, Object?> added = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/discs',
          body: <String, Object?>{'path': discDir},
        ),
      );
      final List<Object?> uids = added['added']! as List<Object?>;
      expect(uids, hasLength(1));
      expect(added['albums'], hasLength(1));
      final String uid = '${uids.single}';

      final Map<String, Object?> listed = asMap(
        await call('GET', '$kMusicCtlRoot/discs'),
      );
      expect(asMap((listed['discs']! as List<Object?>).single)['uid'], uid);

      final Map<String, Object?> titles = asMap(
        await call(
          'GET',
          '$kMusicCtlRoot/discs/:uid/titles',
          params: <String, String>{'uid': uid},
        ),
      );
      expect(titles['titles'], hasLength(2));
      expect(asMap((titles['titles']! as List<Object?>).first)['main'], isTrue);

      final Map<String, Object?> imported = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/discs/:uid/chapters',
          params: <String, String>{'uid': uid},
        ),
      );
      expect(imported['titles'], <int>[1]);
      expect(imported['tracks'], 3);

      final Map<String, Object?> both = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/discs/:uid/chapters',
          params: <String, String>{'uid': uid},
          body: <String, Object?>{
            'titles': <String>['1', '2'],
          },
        ),
      );
      expect(both['tracks'], 5);

      // 再登记同一张盘：只刷新路径，不算新增（撤销不会把它移除）。
      final Map<String, Object?> again = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/discs',
          body: <String, Object?>{'path': discDir},
        ),
      );
      expect(again['added'], isEmpty);

      expect(
        () => call(
          'DELETE',
          '$kMusicCtlRoot/discs/:uid',
          params: <String, String>{'uid': uid},
        ),
        _status(400),
      );
      await call(
        'DELETE',
        '$kMusicCtlRoot/discs/:uid',
        params: <String, String>{'uid': uid},
        body: <String, Object?>{'confirm': true},
      );
      expect(await db.listMusicDiscSources(), isEmpty);
    });

    test('认不出盘 422；没有的 title 400；没有的盘 404', () async {
      final String empty = p.join(tmp.path, 'empty');
      Directory(empty).createSync();
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/discs',
          body: <String, Object?>{'path': empty},
        ),
        _status(422),
      );
      expect(
        () => call(
          'GET',
          '$kMusicCtlRoot/discs/:uid/titles',
          params: <String, String>{'uid': 'nope'},
        ),
        _status(404),
      );
      final Map<String, Object?> added = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/discs',
          body: <String, Object?>{'path': discDir},
        ),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/discs/:uid/chapters',
          params: <String, String>{
            'uid': '${(added['added']! as List<Object?>).single}',
          },
          body: <String, Object?>{
            'titles': <String>['9'],
          },
        ),
        _status(400),
      );
    });
  });

  group('插件', () {
    late String package;

    setUp(() {
      package = p.join(tmp.path, 'lyr.fushiplug');
      File(package).writeAsStringSync('zip');
    });

    test('inspect 给清单；install 没 confirm 409，带 confirm 装上；摘要不符 409', () async {
      final Map<String, Object?> info = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/plugins/inspect',
          body: <String, Object?>{'path': package},
        ),
      );
      expect(info['id'], 'lyr');
      expect(info['permissions'], <String>['network']);
      expect(info['signerChanged'], isFalse);

      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/plugins/install',
          body: <String, Object?>{'path': package},
        ),
        _status(409),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/plugins/install',
          body: <String, Object?>{
            'path': package,
            'confirm': true,
            'digest': 'other',
          },
        ),
        _status(409),
      );
      expect(plugins.installedDigests, isEmpty);

      final Map<String, Object?> installed = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/plugins/install',
          body: <String, Object?>{
            'path': package,
            'confirm': true,
            'digest': 'd-1',
          },
        ),
      );
      expect(installed['installed'], isTrue);
      expect(plugins.installedDigests, <String>['d-1']);
    });

    test('坏包 422；不是插件包扩展名 400；插件不可用 501', () async {
      File(package).writeAsStringSync('bad');
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/plugins/inspect',
          body: <String, Object?>{'path': package},
        ),
        _status(422),
      );
      final String txt = p.join(tmp.path, 'x.txt');
      File(txt).writeAsStringSync('zip');
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/plugins/inspect',
          body: <String, Object?>{'path': txt},
        ),
        _status(400),
      );
      pluginsAvailable = false;
      expect(() => call('GET', '$kMusicCtlRoot/plugins'), _status(501));
    });

    test('列出 / 停用 / 卸载（卸载要 confirm）', () async {
      plugins.enabled['lyr'] = true;
      final Map<String, Object?> listed = asMap(
        await call('GET', '$kMusicCtlRoot/plugins'),
      );
      expect(asMap((listed['plugins']! as List<Object?>).single)['id'], 'lyr');
      final Map<String, Object?> off = asMap(
        await call(
          'PUT',
          '$kMusicCtlRoot/plugins/:id/enabled',
          params: <String, String>{'id': 'lyr'},
          body: <String, Object?>{'enabled': false},
        ),
      );
      expect(off['previous'], isTrue);
      expect(plugins.enabled['lyr'], isFalse);
      expect(
        () => call(
          'PUT',
          '$kMusicCtlRoot/plugins/:id/enabled',
          params: <String, String>{'id': 'nope'},
          body: <String, Object?>{'enabled': true},
        ),
        _status(404),
      );
      expect(
        () => call(
          'DELETE',
          '$kMusicCtlRoot/plugins/:id',
          params: <String, String>{'id': 'lyr'},
        ),
        _status(400),
      );
      // 「来源」页里它的顺序 / 开关条目：卸载（与设置页同一方法）才清，别的来源不动。
      await prefs.setMusicOnlineSourcesRaw(
        serializeLyricsProviders(<LyricsProviderEntry>[
          LyricsProviderEntry(id: musicPluginSourceKey('lyr'), enabled: false),
          const LyricsProviderEntry(id: 'server:s1', enabled: true),
        ]),
      );
      await call(
        'DELETE',
        '$kMusicCtlRoot/plugins/:id',
        params: <String, String>{'id': 'lyr'},
        body: <String, Object?>{'confirm': true},
      );
      expect(plugins.enabled, isEmpty);
      expect(
        parseLyricsProviders(prefs.musicOnlineSourcesRaw),
        const <LyricsProviderEntry>[
          LyricsProviderEntry(id: 'server:s1', enabled: true),
        ],
      );
    });
  });

  group('歌词导出', () {
    test('写到音频旁；已存在 409，overwrite 才覆盖；格式 / 曲目 / 无歌词校验', () async {
      final String audio = p.join(tmp.path, 'song.flac');
      await addTrack('t-1', audio);
      await addTrack('no-lyrics', p.join(tmp.path, 'x.flac'));
      await addTrack('remote', 'https://example.com/a.flac');
      final Map<String, Object?> r = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/lyrics/export',
          params: <String, String>{'uid': 't-1'},
        ),
      );
      expect(r['path'], p.join(tmp.path, 'song.ttml'));
      expect(lyricExports.single, ('t-1', 'ttml', false));
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/lyrics/export',
          params: <String, String>{'uid': 't-1'},
        ),
        _status(409),
      );
      await call(
        'POST',
        '$kMusicCtlRoot/tracks/:uid/lyrics/export',
        params: <String, String>{'uid': 't-1'},
        body: <String, Object?>{'overwrite': true},
      );
      expect(lyricExports.last, ('t-1', 'ttml', true));
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/lyrics/export',
          params: <String, String>{'uid': 't-1'},
          body: <String, Object?>{'format': 'srt'},
        ),
        _status(400),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/lyrics/export',
          params: <String, String>{'uid': 'no-lyrics'},
        ),
        _status(404),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/lyrics/export',
          params: <String, String>{'uid': 'remote'},
        ),
        _status(422),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/lyrics/export',
          params: <String, String>{'uid': 'nope'},
        ),
        _status(404),
      );
    });
  });

  group('音频 CD', () {
    Future<Map<String, Object?>> settle() async {
      for (int i = 0; i < 50; i++) {
        final Map<String, Object?> s = asMap(
          await call('GET', '$kMusicCtlRoot/audio-cd'),
        );
        if (s['status'] != 'running') return s;
        await Future<void>.delayed(Duration.zero);
      }
      fail('抓轨任务没结束');
    }

    test('后台抓轨后导入曲库；不是音频 CD 422、抓不了 501、相对路径 400', () async {
      final String drive = p.join(tmp.path, 'cd');
      final Map<String, Object?> started = asMap(
        await call(
          'POST',
          '$kMusicCtlRoot/audio-cd',
          body: <String, Object?>{'dir': drive},
        ),
      );
      expect(started['taskId'], isNotNull);
      final Map<String, Object?> done = await settle();
      expect(done['status'], 'done');
      expect(done['imported'], 2);
      expect(rippedImports, <String>[p.join(tmp.path, 'ripped')]);

      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/audio-cd',
          body: <String, Object?>{'dir': p.join(tmp.path, 'plain')},
        ),
        _status(422),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/audio-cd',
          body: <String, Object?>{'dir': p.join(tmp.path, 'nocd')},
        ),
        _status(501),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/audio-cd',
          body: <String, Object?>{'dir': 'cd'},
        ),
        _status(400),
      );
    });

    test('取消：不导入，状态 cancelled；没在跑时取消 404', () async {
      await call(
        'POST',
        '$kMusicCtlRoot/audio-cd',
        body: <String, Object?>{'dir': p.join(tmp.path, 'cd')},
      );
      await call('POST', '$kMusicCtlRoot/audio-cd/cancel');
      final Map<String, Object?> s = await settle();
      expect(s['status'], 'cancelled');
      expect(rippedImports, isEmpty);
      expect(
        () => call('POST', '$kMusicCtlRoot/audio-cd/cancel'),
        _status(404),
      );
    });
  });

  group('操作描述', () {
    late OpCatalog catalog;

    setUp(() {
      final OpContext context = OpContext(ref: _Ref(_TestAppModel()));
      catalog = OpCatalog.build(
        routes,
        describeMusicImportOps(OpDescribeKit(context, routes)),
      );
    });

    test('每条路由都有描述；写操作带撤销，其余不带', () {
      expect(catalog.ops, hasLength(routes.length));
      for (final FushiOp op in catalog.ops) {
        if (op.risk == OpRisk.write) expect(op.undo, isNotNull, reason: op.id);
        if (op.risk != OpRisk.write) expect(op.undo, isNull, reason: op.id);
      }
      expect(catalog['music.audio-cd.rip']!.longRunning, isTrue);
      expect(catalog['music.plugin.install']!.risk, OpRisk.irreversible);
    });

    test('加光盘 → 撤销 = 移除这次新登记的盘', () async {
      final OpInvocation added = await OpInvoker(catalog).invoke(
        'music.disc.add',
        <String, Object?>{'path': discDir},
        caller: OpCaller.model,
        captureUndo: true,
      );
      expect(await db.listMusicDiscSources(), hasLength(1));
      final Map<String, Object?> payload =
          jsonDecode(jsonEncode(added.undo!.payload)) as Map<String, Object?>;
      final OpUndoOutcome outcome = await catalog['music.disc.add']!.undo!
          .revert(payload);
      expect(outcome.status, OpUndoStatus.done);
      expect(await db.listMusicDiscSources(), isEmpty);
    });
  });
}
