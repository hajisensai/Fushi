// BUG-2429：OpenSubtitles 的「启用」默认值曾在三处各自表达且互相矛盾——
// [OpenSubtitlesConfig] 构造默认 true，设置详情页的草稿空态硬写 false，设置列表
// 在偏好为 null 时又假造一个 true 的配置来显示「已内置」，而运行时装配遇到 null
// 直接不装配。结果：用户进过一次详情页、碰过任意字段，那个没人选过的 false 就被
// 落盘，内置应用密钥从此形同虚设，设置列表却仍显示「已内置」。
//
// 本文件钉的是修复后的不变式：默认值只有 [OpenSubtitlesConfig.unconfigured] 一处，
// 偏好读取永不返回 null，存量脏数据一次性归一且只归一一次。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository preferences;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
  });
  tearDown(() async {
    preferences.dispose();
    await db.close();
  });

  test('未配置过时读到的是启用态，而不是 null', () async {
    await preferences.loadFromDb();
    final OpenSubtitlesConfig config =
        preferences.videoSubtitleOpenSubtitlesConfig;
    expect(config.enabled, isTrue);
    expect(config.apiKey, isEmpty);
    // 与构造默认同源：默认值只有一处。
    expect(config.enabled, OpenSubtitlesConfig.unconfigured().enabled);
    expect(config.baseUrl, OpenSubtitlesConfig.unconfigured().baseUrl);
  });

  test('解码失败的脏值同样退回启用态而不是 null', () async {
    await preferences.setPref(
      'video_subtitle_opensubtitles_config',
      'not json at all',
    );
    expect(preferences.videoSubtitleOpenSubtitlesConfig.enabled, isTrue);
  });

  test('空草稿写下的 enabled=false 被一次性归一，且只归一一次', () async {
    // 空草稿的指纹：一条自有凭据都没有，却是关闭态。
    await preferences.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: '', enabled: false),
    );
    expect(preferences.videoSubtitleOpenSubtitlesConfig.enabled, isFalse);

    await preferences.loadFromDb();
    expect(
      preferences.videoSubtitleOpenSubtitlesConfig.enabled,
      isTrue,
      reason: '存量脏数据应被修复',
    );

    // 修复之后用户仍然可以自己关掉，并且关得住——否则这条修复就成了「关不掉」。
    await preferences.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: '', enabled: false),
    );
    await preferences.loadFromDb();
    expect(
      preferences.videoSubtitleOpenSubtitlesConfig.enabled,
      isFalse,
      reason: '标记键必须让归一只发生一次',
    );
  });

  test('填过自有凭据的关闭态是用户意图，不动它', () async {
    await preferences.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: 'user-key', enabled: false),
    );
    await preferences.loadFromDb();
    expect(preferences.videoSubtitleOpenSubtitlesConfig.enabled, isFalse);
    expect(preferences.videoSubtitleOpenSubtitlesConfig.apiKey, 'user-key');

    // username / password 任一非空也算「配置过」。
    await preferences.setPref(
      PreferencesRepository.openSubtitlesEnabledRepairedKey,
      false,
    );
    await preferences.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: '', username: 'someone', enabled: false),
    );
    await preferences.loadFromDb();
    expect(preferences.videoSubtitleOpenSubtitlesConfig.enabled, isFalse);
  });
}
