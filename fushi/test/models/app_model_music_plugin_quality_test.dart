import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_gate.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginQuality;

import '../helpers/test_platform_services.dart';

/// 设置 › 音乐 › 音质「Online plugin quality」的效果探针：改默认档后持久化、插件取流
/// 装配点（[musicPluginPlaybackHost] 的 quality 回调，mpv 后端打开插件曲目时读它）拿到
/// 新档、并清掉播放器里「只对这首」的临时选择。原位重开 / 只重排下一首的范围由
/// test/media/music/music_engine_reopen_current_test.dart 咬住。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_path_provider_plugin_quality',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late AppModel appModel;
  final String trackA = musicPluginTrackPath('demo', 'a');
  final String trackB = musicPluginTrackPath('demo', 'b');

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_app_model_quality');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  test('没单独设过时由服务器码率上限反推（升级后听到的不变）', () async {
    expect(prefs.musicPluginQualityWire, isNull);
    expect(appModel.musicPluginQuality, MusicPluginQuality.lossless);
    await prefs.setMusicServerMaxBitrate(320);
    expect(appModel.musicPluginQuality, MusicPluginQuality.high);
  });

  test('改默认档：持久化、取流装配点拿到新档、清掉「只对这首」', () async {
    await appModel.setMusicPluginQualityOverride(
      trackA,
      MusicPluginQuality.standard,
    );
    expect(appModel.musicPluginQualityFor(trackA), MusicPluginQuality.standard);
    expect(appModel.musicPluginQualityFor(trackB), MusicPluginQuality.lossless);

    await appModel.setMusicPluginQuality(MusicPluginQuality.hires);

    expect(prefs.musicPluginQualityWire, MusicPluginQuality.hires.wire);
    expect(appModel.musicPluginQualityFor(trackA), MusicPluginQuality.hires);
    expect(appModel.musicPluginQualityFor(trackB), MusicPluginQuality.hires);
    final MusicPluginPlaybackHost? host = musicPluginPlaybackHost;
    if (isMusicPluginSourcesAvailable) {
      expect(host, isNotNull);
      expect(host!.quality(trackA), MusicPluginQuality.hires);
    }

    // 落库：新开一份仓库读到的是同一档。
    final PreferencesRepository reread = PreferencesRepository(db);
    await reread.loadFromDb();
    addTearDown(reread.dispose);
    expect(reread.musicPluginQualityWire, MusicPluginQuality.hires.wire);
  });
}
