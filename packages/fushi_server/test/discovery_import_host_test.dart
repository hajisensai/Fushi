import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart' show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/discovery_models.dart' show DiscoveryMediaKind;
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/discovery_import_host.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端「按域入库」端口：有声书（正文 + 字幕 + 音频）走引擎对齐落库；游戏与
/// 能力位外的域以 `unsupportedOnThisHost` 挡下。
void main() {
  late Directory tmp;
  late ServerPaths paths;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_discovery_import_');
    paths = ServerPaths(p.join(tmp.path, 'data'));
    await paths.ensureLayout();
    // 与生产同一个装配入口：有声书持久目录的根也由它装上。
    installServerHostBindings(
      config: ServerConfig.defaults(dataDir: paths.dataDir),
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
    );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    engineLog = const StderrEngineLogSink();
    enginePaths = const UninstalledEnginePaths();
    AudiobookStorage.documentsRootResolver = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('装配入口把有声书持久根接到 <documents>/audiobooks', () async {
    expect(p.normalize(await AudiobookStorage.audiobooksRootDir()), p.normalize(p.join(paths.documents.path, 'audiobooks')));
  });

  test('有声书包：正文转 EPUB 入库 + 字幕对齐 + 音频落持久目录', () async {
    final Directory pack = Directory(p.join(tmp.path, 'dl', 'Neko'))..createSync(recursive: true);
    final File text = File(p.join(pack.path, 'neko.txt'))
      ..writeAsStringSync('吾輩は猫である。\n\n名前はまだ無い。\n');
    final File srt = File(p.join(pack.path, 'neko.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:02,000\n吾輩は猫である。\n\n'
          '2\n00:00:02,000 --> 00:00:04,000\n名前はまだ無い。\n');
    final File audio = File(p.join(pack.path, 'neko.mp3'))..writeAsBytesSync(List<int>.filled(64, 7));

    final DiscoveryImportOutcome outcome = await serverDiscoveryImporter(db)(
      DiscoveryMediaKind.audiobook,
      <String>[text.path, srt.path, audio.path],
    );
    expect(outcome.importedCount, 1);
    final List<AudiobookRow> audiobooks = await db.getAllAudiobooks();
    expect(audiobooks, hasLength(1));
    expect(audiobooks.single.audioPathsJson, contains('neko.mp3'));
    expect(audiobooks.single.audioPathsJson, isNot(contains(pack.path.replaceAll(r'\', r'\\'))),
        reason: '音频拷进持久目录，不引用下载目录（删种子不影响库）');
    expect(await db.getSrtBookByBookKey(audiobooks.single.bookKey), isNotNull);
  });

  test('游戏与能力位外的域：unsupportedOnThisHost，不碰库', () async {
    final File exe = File(p.join(tmp.path, 'Game', 'game.exe'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[0x4d, 0x5a]);
    await expectLater(
      serverDiscoveryImporter(db)(DiscoveryMediaKind.game, <String>[exe.path]),
      throwsA(isA<DiscoveryImportBlockedException>()
          .having((DiscoveryImportBlockedException e) => e.blocker, 'blocker', DiscoveryImportBlocker.unsupportedOnThisHost)),
    );
    expect(kServerDownloadDiscoveryKinds, isNot(contains(DiscoveryMediaKind.game.name)));
  });
}
