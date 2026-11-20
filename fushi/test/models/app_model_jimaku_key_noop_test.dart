import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';

import '../helpers/test_platform_services.dart';

/// BUG-4973：字幕搜索 / 合集面板的「初始 key」不随保存刷新，改过一次 key 之后
/// 每次搜索都会按**同一个值**调 [AppModel.setJimakuApiKey]。值没变时不得作废
/// 查字幕 registry（作废 = 下次搜索现建 http client、重读 AJATT 目录）、不得重建
/// 下载管线运行时。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel app;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    // 只留 Jimaku 一家：OpenSubtitles 关掉、AJATT 关掉（它要 support 目录），
    // SubDL 默认没 key 不装配。
    await prefs.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: '', enabled: false),
    );
    await prefs.setVideoSubtitleAjattEnabled(false);
    app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wirePreferencesForTesting(prefs);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  test('re-saving the same Jimaku key keeps the subtitle registry', () async {
    await app.setJimakuApiKey('key-1');
    final VideoSubtitleRegistry? first = await app.subtitleSearchRegistry();
    expect(first, isNotNull);
    expect(first!.providers, hasLength(1));

    await app.setJimakuApiKey('key-1');
    final VideoSubtitleRegistry? second = await app.subtitleSearchRegistry();
    expect(identical(first, second), isTrue);
  });

  test('a changed Jimaku key still rebuilds the registry', () async {
    await app.setJimakuApiKey('key-1');
    final VideoSubtitleRegistry? first = await app.subtitleSearchRegistry();

    await app.setJimakuApiKey('key-2');
    final VideoSubtitleRegistry? second = await app.subtitleSearchRegistry();
    expect(second, isNotNull);
    expect(identical(first, second), isFalse);
    expect(app.jimakuApiKey, 'key-2');
  });
}
