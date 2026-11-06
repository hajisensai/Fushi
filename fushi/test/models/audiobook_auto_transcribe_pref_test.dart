import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase database;
  late PreferencesRepository preferences;

  setUp(() async {
    database = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    preferences = PreferencesRepository(database);
    await preferences.loadFromDb();
  });

  tearDown(() async {
    preferences.dispose();
    await database.close();
  });

  test('有声书下载后自动转录默认关闭，手动打开写穿数据库', () async {
    expect(
      preferences.audiobookAutoTranscribe,
      isFalse,
      reason: '没有正文时自动转录质量差，下载后不应默认自动转录',
    );
    await preferences.setAudiobookAutoTranscribe(value: true);
    final PreferencesRepository reopened = PreferencesRepository(database);
    await reopened.loadFromDb();
    expect(reopened.audiobookAutoTranscribe, isTrue);
    reopened.dispose();
  });
}
