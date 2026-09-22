import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 底部细进度条偏好 `video_slim_progress_bar` 的默认值与记忆语义。
///
/// 默认值是这个功能唯一的「新装用户看到什么」入口：显隐判据
/// （`videoSlimProgressBarVisible`）与页面接线各有自己的测试，但它们都从
/// `preferenceEnabled` 往下算，拿到的开关位是真是假全由这里决定。首版默认开，
/// 2026-09-22 改判为默认关——控制条淡出本身就是「把画面让干净」。
FushiDatabase _testDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  test('默认关：没动过设置的用户，控制条淡出后画面是干净的', () {
    expect(prefs.videoSlimProgressBar, isFalse);
  });

  test('开了之后读得回来', () async {
    await prefs.setVideoSlimProgressBar(true);
    expect(prefs.videoSlimProgressBar, isTrue);
  });

  test('切过开关的用户保留存值，不会被默认值覆盖', () async {
    // 首版默认开期间手动开着的人：这次改默认不许把他们一起关掉。
    await prefs.setVideoSlimProgressBar(true);
    await prefs.loadFromDb();
    expect(prefs.videoSlimProgressBar, isTrue);

    // 反过来手动关掉的人也一样，存值优先于默认值。
    await prefs.setVideoSlimProgressBar(false);
    await prefs.loadFromDb();
    expect(prefs.videoSlimProgressBar, isFalse);
  });

  test('键登记在 preference_keys.dart', () {
    expect(kKnownPreferenceKeys, contains('video_slim_progress_bar'));
  });
}
