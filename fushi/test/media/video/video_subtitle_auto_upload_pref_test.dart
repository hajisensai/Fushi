import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「导入的字幕自动上传到服务端」偏好 `video_subtitle_auto_upload_to_host` 的
/// 默认值与记忆语义。
///
/// 这个开关管 BUG-2728 的自动上传：远端（互联 host）视频上导入 / 重定时的字幕
/// 上传到 host 并设为该集默认字幕。默认开——所有者报 BUG-2728 时要的就是自动
/// 上传，PR #1688 按此合入；开关是事后追加的「能关」，不改默认。关掉时视频页
/// 不调上传入口，由 interconnect_video_default_subtitle_test 的源码守卫钉住。
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

  test('默认开：升级后沿用 PR #1688 的自动上传行为', () {
    expect(prefs.videoSubtitleAutoUploadToHost, isTrue);
  });

  test('关掉之后读得回来，重新加载后仍是关', () async {
    await prefs.setVideoSubtitleAutoUploadToHost(false);
    expect(prefs.videoSubtitleAutoUploadToHost, isFalse);
    await prefs.loadFromDb();
    expect(prefs.videoSubtitleAutoUploadToHost, isFalse);

    await prefs.setVideoSubtitleAutoUploadToHost(true);
    await prefs.loadFromDb();
    expect(prefs.videoSubtitleAutoUploadToHost, isTrue);
  });

  test('键登记在 preference_keys.dart', () {
    expect(
      kKnownPreferenceKeys,
      contains('video_subtitle_auto_upload_to_host'),
    );
  });
}
