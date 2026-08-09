import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// [PrefRedactionPolicy] 是「一条 pref 能不能离开本设备」的唯一真相源。
///
/// 这套测试守的是它取代的那三份各自为政的实现留下的两个洞：
/// 1. 形状兜底被 `sync_` 前缀锁死 → 别的子系统的凭据全员漏网；
/// 2. `profile_settings` 通道压根没有凭据判定。
/// 第 2 条的端到端证据在 `backup_service_test.dart`，这里守判定本身。
void main() {
  group('PrefRedactionPolicy.isDeviceLocalOrCredential', () {
    test('redacts every device-local key (the whitelist is the main line)', () {
      for (final String key in SyncRepository.deviceLocalPrefKeys) {
        expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isTrue,
            reason: '$key 是设备本地 key，必须剔除');
      }
    });

    test(
        'redacts the non-sync_ credentials the old sync_-anchored fallback '
        'let through', () {
      // 回归守卫：旧实现是 `if (!lower.startsWith('sync_')) return false;`，
      // 下面每一个都因此返回 false —— 也就是分享 Profile / 导出备份时原样出境。
      const List<String> previouslyLeaking = <String>[
        // 网络来源（SFTP/FTP）登录密码 + 私钥 PEM，按来源行 id 展开。
        'media_source_secret_1',
        'media_source_secret_42',
        // qBittorrent WebUI 配置：值里裹着明文密码，key 本身不含任何凭据子串，
        // 只能靠点名（这条同时守着 sensitiveKeys 不被误删）。
        'qb_connection_config',
        // 第三方服务 API key。
        'yomitan_api_key',
        'jimaku_api_key',
        'manga_cloud_ocr_api_key',
        'video_scraper_tmdb_api_key',
        'video_metadata_fanart_api_key',
        'video_metadata_bangumi_token',
        'video_metadata_douban_authorized_token',
        'video_metadata_douban_authorized_endpoint',
      ];
      for (final String key in previouslyLeaking) {
        expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isTrue,
            reason: '$key 含凭据，必须剔除（旧实现在此漏网）');
      }
    });

    test('shape fallback is NOT anchored on any prefix', () {
      // 这是与旧实现的本质差异：凭据形状与所属子系统无关。
      for (final String substring in PrefRedactionPolicy.credentialSubstrings) {
        expect(
            PrefRedactionPolicy.isDeviceLocalOrCredential(
                'some_future_subsystem_$substring'),
            isTrue,
            reason: '含 $substring 的新 key 必须被兜底拦下，无论前缀');
      }
    });

    test('is case-insensitive on the shape fallback', () {
      expect(PrefRedactionPolicy.isDeviceLocalOrCredential('Some_PASSWORD_Key'),
          isTrue);
      expect(
          PrefRedactionPolicy.isDeviceLocalOrCredential('MEDIA_SOURCE_'
                  'SECRET_3'
              .toLowerCase()),
          isTrue);
    });

    test('does NOT redact ordinary settings/content keys (no false positives)',
        () {
      // 这些必须继续随备份跨设备旅行。任何一条变 true 都是真实功能回归：
      // 用户的设置/内容注册表会在导出时被静默丢弃。
      const List<String> mustTravel = <String>[
        // sync_* 里的行为开关（是用户设置，不是凭据——见 sync_repository 注释）。
        'sync_auto_enabled',
        'sync_content_enabled',
        'sync_stats_enabled',
        'sync_dictionary_enabled',
        // 内容注册表（backup_service 的 settingsPrefPredicate 明确保留的那批）。
        'favorite_sentences',
        'local_audio_dbs',
        'audio_source_configs',
        'font_catalog',
        // 进度 / 普通显示设置。
        'audiobook_pos_somebook',
        'app_ui_scale',
        'eink_mode',
        'reader_font_size',
        'current_home_tab_index',
        // 视频刮削的普通行为偏好应继续随备份/Profile 迁移；只有凭据留在设备。
        'video_metadata_primary_provider',
        'video_metadata_locale',
      ];
      for (final String key in mustTravel) {
        expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isFalse,
            reason: '$key 是设置/内容，误剔除会让它无法跨设备恢复');
      }
    });

    test('every explicitly named sensitive key is actually matched', () {
      // sensitiveKeys 里若有条目其实已被子串兜底覆盖，是冗余而非错误；
      // 但反过来——列了却没被 matched——说明判定链断了。
      for (final String key in PrefRedactionPolicy.sensitiveKeys) {
        expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isTrue);
      }
      for (final String prefix in PrefRedactionPolicy.sensitiveKeyPrefixes) {
        expect(PrefRedactionPolicy.isDeviceLocalOrCredential('${prefix}7'),
            isTrue);
      }
    });
  });
}
