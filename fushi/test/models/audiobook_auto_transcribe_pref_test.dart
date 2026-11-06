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

  test('自动转录总开关默认开(尊重 PR #3000 前的默认与用户显式关闭),关掉写穿数据库', () async {
    expect(
      preferences.audiobookAutoTranscribe,
      isTrue,
      reason: '总开关默认开;用户显式关掉的(存了 false)才是拒绝一切自动转录',
    );
    await preferences.setAudiobookAutoTranscribe(value: false);
    final PreferencesRepository reopened = PreferencesRepository(database);
    await reopened.loadFromDb();
    expect(reopened.audiobookAutoTranscribe, isFalse);
    reopened.dispose();
  });

  test('没有正文也转录的子开关默认关闭,手动打开写穿数据库', () async {
    expect(
      preferences.audiobookAutoTranscribeWithoutText,
      isFalse,
      reason: '没有正文时自动转录质量差,下载后不应默认生成独立字幕书',
    );
    await preferences.setAudiobookAutoTranscribeWithoutText(value: true);
    final PreferencesRepository reopened = PreferencesRepository(database);
    await reopened.loadFromDb();
    expect(reopened.audiobookAutoTranscribeWithoutText, isTrue);
    expect(reopened.audiobookAutoTranscribe, isTrue);
    reopened.dispose();
  });
}
