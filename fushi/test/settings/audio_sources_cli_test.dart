import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/audio_source_list_edit.dart';
import 'package:fushi/src/settings/audio_sources_cli.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 内存里的音频来源存储：记下每次整表落盘的参数（与对话框关闭时同一个
/// setAudioSourceConfigs）。
class _AppModel extends AppModel {
  _AppModel(this._sources) : super(testPlatformServices());

  List<AudioSourceConfig> _sources;
  final List<DeleteScope> scopes = <DeleteScope>[];
  final List<Map<String, List<LocalAudioSourcePref>>> prefsWrites =
      <Map<String, List<LocalAudioSourcePref>>>[];
  final Map<String, List<LocalAudioSourcePref>> subSources =
      <String, List<LocalAudioSourcePref>>{};
  final List<String> imported = <String>[];

  @override
  List<AudioSourceConfig> get audioSourceConfigs =>
      List<AudioSourceConfig>.of(_sources);

  @override
  Future<void> setAudioSourceConfigs(
    List<AudioSourceConfig> sources, {
    Map<String, List<LocalAudioSourcePref>> sourcesByPath =
        const <String, List<LocalAudioSourcePref>>{},
    DeleteScope scope = DeleteScope.keepLocalOnly,
  }) async {
    _sources = List<AudioSourceConfig>.of(sources);
    scopes.add(scope);
    prefsWrites.add(sourcesByPath);
  }

  @override
  Future<LocalAudioDbEntry> importLocalAudioDbFile(
    String sourcePath, {
    required String displayName,
    bool reference = false,
  }) async {
    if (sourcePath.endsWith('.zip')) {
      throw InvalidLocalAudioDbException(sourcePath);
    }
    imported.add('$sourcePath|$reference');
    return LocalAudioDbEntry(
      path: 'local_audio/${displayName}_${imported.length}.db',
      displayName: displayName,
    );
  }

  @override
  List<LocalAudioSourcePref> sourcePrefsForLocalDb(String path) =>
      subSources[path] ?? const <LocalAudioSourcePref>[];

  @override
  Future<List<String>> listLocalAudioSources(String path) async => <String>[
    'nhk16',
    'jpod',
    'forvo',
  ];

  @override
  Future<void> setLocalAudioDbSources(
    String path,
    List<LocalAudioSourcePref> prefs,
  ) async {
    subSources[path] = prefs;
  }
}

/// 当前宿主平台上的绝对路径（CI 跑 Linux、本机跑 Windows）。CLI 的 `path`
/// 判据按宿主 `p.isAbsolute`，写死 Windows 盘符路径在 Linux 上会被当成相对路径拒掉。
String _absPath(List<String> parts) =>
    p.joinAll(<String>[p.rootPrefix(p.current), 'fushi_cli_test', ...parts]);

const String _url = 'https://audio.example/?term={term}&reading={reading}';

void main() {
  group('编辑规则（对话框与 CLI 共用）', () {
    test('远端地址校验：http(s) + 占位符，折全角', () {
      expect(isValidRemoteAudioUrl(_url), isTrue);
      expect(isValidRemoteAudioUrl('https://audio.example/?q=x'), isFalse);
      expect(isValidRemoteAudioUrl('ftp://a/{term}'), isFalse);
      expect(isValidRemoteAudioUrl('https：//a.example/{term}'), isTrue);
    });

    test('重置：保留互联源与本地库，远端只剩 Anki 预设（关闭）', () {
      final List<AudioSourceConfig> reset = resetAudioSourcesToDefaults(
        <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: _url),
          AudioSourceConfig.localAudio(label: 'L', path: 'a.db', enabled: true),
          AudioSourceConfig.fushiRemote(enabled: true),
        ],
        ankiLocalAudioUrl: 'http://localhost:5050/?term={term}',
      );
      expect(reset.map((AudioSourceConfig s) => s.kind), <AudioSourceKind>[
        AudioSourceKind.fushiRemote,
        AudioSourceKind.remoteAudio,
        AudioSourceKind.localAudio,
      ]);
      expect(reset[1].label, 'Anki');
      expect(reset[1].enabled, isFalse);
    });
  });

  group('控制通道', () {
    test('ls：id 稳定、重复值补 #2', () {
      final _AppModel app = _AppModel(<AudioSourceConfig>[
        AudioSourceConfig.fushiRemote(),
        AudioSourceConfig.remoteAudio(url: _url),
        AudioSourceConfig.remoteAudio(url: _url),
        AudioSourceConfig.localAudio(label: 'L', path: 'x.db'),
      ]);
      expect(
        listAudioSourcesForCli(app).map((Map<String, Object?> r) => r['id']),
        <String>[
          'fushi_remote',
          'remote:$_url',
          'remote:$_url#2',
          'local:x.db',
        ],
      );
    });

    test('add remote：默认插最前、全角折掉、重复拒绝；落盘 scope = syncEverywhere', () async {
      final _AppModel app = _AppModel(<AudioSourceConfig>[
        AudioSourceConfig.fushiRemote(),
      ]);
      final Map<String, Object?> added = await addAudioSourceForCli(
        app,
        <String, String>{'url': 'https：//audio.example/?term={term}'},
      );
      expect(added['kind'], 'remote');
      expect(added['position'], 0);
      expect(added['url'], 'https://audio.example/?term={term}');
      expect(app.scopes.single, DeleteScope.syncEverywhere);
      await expectLater(
        addAudioSourceForCli(app, <String, String>{
          'url': 'https://audio.example/?term={term}',
        }),
        throwsArgumentError,
      );
      await expectLater(
        addAudioSourceForCli(app, <String, String>{'url': 'https://a/no'}),
        throwsArgumentError,
      );
      await expectLater(
        addAudioSourceForCli(app, <String, String>{'kind': 'fushi_remote'}),
        throwsArgumentError,
        reason: '互联源只能有一条',
      );
    });

    test('add local：导入库文件（尊重 reference），坏文件给可读错误', () async {
      final _AppModel app = _AppModel(<AudioSourceConfig>[]);
      final String dbPath = _absPath(<String>['audio', 'android.db']);
      final Map<String, Object?> added = await addAudioSourceForCli(
        app,
        <String, String>{'path': dbPath, 'reference': 'true', 'position': '5'},
      );
      expect(added['kind'], 'local');
      expect(added['enabled'], isTrue);
      expect(app.imported.single, '$dbPath|true');
      await expectLater(
        addAudioSourceForCli(app, <String, String>{
          'path': _absPath(<String>['a', 'b.zip']),
        }),
        throwsArgumentError,
      );
      await expectLater(
        addAudioSourceForCli(app, <String, String>{'path': 'rel.db'}),
        throwsArgumentError,
      );
    });

    test('set：启停 / 挪位置 / 改地址；本地换库沿用子来源偏好', () async {
      final _AppModel app = _AppModel(<AudioSourceConfig>[
        AudioSourceConfig.remoteAudio(url: _url),
        AudioSourceConfig.localAudio(label: 'L', path: 'old.db', enabled: true),
      ]);
      app.subSources['old.db'] = <LocalAudioSourcePref>[
        const LocalAudioSourcePref(name: 'jpod', enabled: false),
      ];
      final Map<String, Object?> moved = await updateAudioSourceForCli(
        app,
        'local:old.db',
        <String, String>{'position': '0', 'enabled': 'false'},
      );
      expect(moved['position'], 0);
      expect(moved['enabled'], isFalse);

      final Map<String, Object?> replaced = await updateAudioSourceForCli(
        app,
        'local:old.db',
        <String, String>{
          'path': _absPath(<String>['new.db']),
        },
      );
      final String newPath = replaced['path']! as String;
      expect(newPath, isNot('old.db'));
      expect(app.prefsWrites.last[newPath], <LocalAudioSourcePref>[
        const LocalAudioSourcePref(name: 'jpod', enabled: false),
      ]);

      final Map<String, Object?> url = await updateAudioSourceForCli(
        app,
        'remote:$_url',
        <String, String>{'url': 'https://b.example/{reading}'},
      );
      expect(url['url'], 'https://b.example/{reading}');
      await expectLater(
        updateAudioSourceForCli(app, 'nope', <String, String>{
          'enabled': 'true',
        }),
        throwsArgumentError,
      );
    });

    test('rm：互联源不能删；reset 走同一条重置规则', () async {
      final _AppModel app = _AppModel(<AudioSourceConfig>[
        AudioSourceConfig.fushiRemote(),
        AudioSourceConfig.remoteAudio(url: _url),
      ]);
      await expectLater(
        removeAudioSourceForCli(app, 'fushi_remote'),
        throwsArgumentError,
      );
      await removeAudioSourceForCli(app, 'remote:$_url');
      expect(app.audioSourceConfigs, hasLength(1));
      final List<Map<String, Object?>> reset = await resetAudioSourcesForCli(
        app,
      );
      expect(reset.map((Map<String, Object?> r) => r['kind']), <String>[
        'fushi_remote',
        'remote',
      ]);
    });

    test('本地子来源：查询 / 设顺序与启停 / 未知名拒绝', () async {
      final _AppModel app = _AppModel(<AudioSourceConfig>[
        AudioSourceConfig.localAudio(label: 'L', path: 'x.db', enabled: true),
      ]);
      final Map<String, Object?> listed = await localAudioSubSourcesForCli(
        app,
        path: 'x.db',
      );
      expect(listed['available'], <String>['nhk16', 'jpod', 'forvo']);
      await localAudioSubSourcesForCli(app, path: 'x.db', spec: 'forvo,!nhk16');
      expect(app.subSources['x.db'], <LocalAudioSourcePref>[
        const LocalAudioSourcePref(name: 'forvo'),
        const LocalAudioSourcePref(name: 'nhk16', enabled: false),
      ]);
      await expectLater(
        localAudioSubSourcesForCli(app, path: 'x.db', spec: 'missing'),
        throwsArgumentError,
      );
      await expectLater(
        localAudioSubSourcesForCli(app, path: 'y.db'),
        throwsArgumentError,
      );
    });
  });
}
