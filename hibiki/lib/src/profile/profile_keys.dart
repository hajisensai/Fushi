import 'dart:convert';

import 'package:hibiki_anki/hibiki_anki.dart';

import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/sync/pref_redaction_policy.dart';

class ProfileKeys {
  ProfileKeys._();

  static const String categoryAnki = 'anki';
  static const String categoryPref = 'pref';

  /// v63 已从 live preferences 与 Profile 副本中删除的旧全局超分键。
  ///
  /// 每游戏真值是 `galgames.upscaling_mode`；此键只保留为输入拒绝标识，防止
  /// 旧快照或旧分享 JSON 在升级后把废弃数据重新写回。
  static const String obsoleteGalgameUpscalingModePrefKey =
      'galgame_magpie_upscaling_mode';

  /// TODO-1077: per-profile snapshot of the `dictionary_metadata` Drift table
  /// (enable list / order / formatKey / type / hidden+collapsed languages /
  /// metadata). This is a NEW category, distinct from the legacy pref-style
  /// [categoryDictionary] below — that one only ever carried old v1 pref keys
  /// and must not be reused for the metadata-table snapshot. One
  /// profile_settings row per dictionary: key = dictionary name, value = the
  /// JSON blob produced by [ProfileRepository]'s dictionary-meta serializer.
  static const String categoryDictionaryMeta = 'dictionary_meta';

  // Legacy categories (pre-v2 snapshots stored dictionary/reader separately)
  static const String categoryDictionary = 'dictionary';
  static const String categoryReader = 'reader';

  static const Set<String> _excludedPrefKeys = {
    'active_profile_id',
    'first_time_setup',
    'current_home_tab_index',
    'startup_default_dictionary_tab',
    'app_ui_scale',
    'app_ui_scale_mode',
    'app_locale',
    // E-ink mode describes the physical display the app is running on (same
    // family as app_ui_scale), never a per-profile reading preference —
    // snapshotting it would flip the whole app's colors on profile switch.
    'eink_mode',
    'last_selected_deck',
    'last_selected_dictionary_format',
    'last_selected_model',
    'update_never_remind',
    'update_auto_install',
    'update_beta_channel',
    // HBK-AUDIT-045: keep ALL update-channel/policy keys app-global so the
    // debug channel isn't asymmetrically profile-scoped vs the others.
    'update_debug_channel',
    // TODO-871: custom update proxy is a global update-policy key (same family as
    // update_beta_channel / update_debug_channel) — never per-profile snapshot.
    'update_custom_proxy',
    // Network routes describe this device, not a reading profile. Restoring a
    // different profile must not silently redirect AniList/Nyaa/Jimaku.
    'download_network_proxy_mode',
    'download_custom_proxy',
    // TODO-1961: the download folder (and the history of folders we still have
    // to recognise) describes this device's disks, not a reading profile.
    // Snapshotting it would make a profile switch redirect downloads onto a
    // path that may not even exist on this machine.
    'download_save_root',
    'download_save_root_history',
    obsoleteGalgameUpscalingModePrefKey,
    // TODO-855: the monotonic prefs-version counter is the cross-process signal
    // the :popup process reads to decide whether to refresh its warm-reuse
    // pref cache. It must stay app-global and monotonic — snapshotting it
    // into a profile (and restoring/wiping it on profile switch) would make
    // the counter non-monotonic and break change detection.
    PreferencesRepository.prefsVersionKey,
  };

  static const List<String> _excludedPrefPrefixes = [
    'current_source/',
    // BUG-1019: per-book audiobook playback STATE lives in prefs
    // (`audiobook_<kind>_<bookKey>`, see AudiobookRepository). These are
    // progress/content data — the same family backup_service already treats as
    // the `progress` category (`key NOT LIKE 'audiobook_pos_%'` in
    // settingsPrefPredicate) — NOT per-profile reading preferences. Snapshotting
    // them meant a profile switch pruned the position prefs (progress reset to
    // 0) while restoring a stale speed snapshot (playback suddenly fast/slow).
    // `audiobook_pos_` also covers `audiobook_pos_at_` (its LWW timestamp twin).
    'audiobook_pos_',
    'audiobook_follow_',
    'audiobook_delay_',
    'audiobook_speed_',
    'audiobook_volume_',
    'audiobook_image_pause_',
    'audiobook_health_overlay_',
    // TODO-2487: airing calendar fetch cache is device-local network cache,
    // not a reading preference. Snapshotting it per profile would restore
    // stale schedules on profile switch for zero benefit.
    'airing_calendar_',
  ];

  /// BUG-1018 (A4): per-item display-name overrides are CONTENT tied to a
  /// media item, not reading preferences. Their persisted form is
  /// `src:<sourceId>:override_title://<sourceId>/<uniqueKey>` (see
  /// [MediaSource.getOverrideTitleKey] + `dbSourcePrefKey`), so the marker is
  /// matched as a substring — excluding them from profile snapshots keeps a
  /// rename visible across profile switches instead of being pruned/reverted.
  static const String _overrideTitleMarker = 'override_title://';

  static bool isExcludedPref(String key) {
    // 凭据 / 设备本地 key 绝不进 Profile 快照（[PrefRedactionPolicy] 是这条判定
    // 的唯一真相源，与备份导出、Profile 分享 JSON 共用）。
    //
    // 这里此前完全没有凭据判定，造成两个独立缺陷：
    // 1. 泄漏：`snapshotCurrentSettings` 把全部 prefs（含 WebDAV/SFTP 密码、
    //    OAuth refresh token、API key）复制进 `profile_settings`，而备份导出只
    //    DELETE `preferences` —— 凭据以另一张表原样出境。
    // 2. 串号：`applyProfile` 会用快照覆盖当前 prefs，于是切换 Profile 会把
    //    A Profile 快照里的同步凭据写进 B Profile。这些 key 按定义是**设备
    //    本地**的（见 [SyncRepository.deviceLocalPrefKeys] 的命名与文档），本来
    //    就不该跟着 Profile 走。
    //
    // 放在 isExcludedPref 里而不是各调用点，是因为快照的写（snapshot）、读
    // （apply 的 restore map）与剪枝（apply 的 prune loop）三处已经全部走这个
    // 谓词：一处收敛即三处生效，且 prune 不再删除凭据行 —— 切 Profile 时本机
    // 凭据原样留存，正是想要的行为。存量快照里已有的凭据行由读侧过滤失效，
    // 无需 schema 迁移；导出副本里的那份由 `_stripCredentials` 删除。
    if (PrefRedactionPolicy.isDeviceLocalOrCredential(key)) return true;
    if (_excludedPrefKeys.contains(key)) return true;
    for (final prefix in _excludedPrefPrefixes) {
      if (key.startsWith(prefix)) return true;
    }
    if (key.contains(_overrideTitleMarker)) return true;
    if (key.endsWith('/last_picked_file')) return true;
    return false;
  }

  static Map<String, String> ankiSettingsToMap(AnkiSettings s) => {
        'selectedDeckId': s.selectedDeckId?.toString() ?? '',
        'selectedDeckName': s.selectedDeckName ?? '',
        'selectedNoteTypeId': s.selectedNoteTypeId?.toString() ?? '',
        'selectedNoteTypeName': s.selectedNoteTypeName ?? '',
        'fieldMappings': jsonEncode(s.fieldMappings),
        'tags': s.tags,
        'tagIncludeHibiki': s.tagIncludeHibiki.toString(),
        'tagIncludeCategory': s.tagIncludeCategory.toString(),
        'allowDupes': s.allowDupes.toString(),
        'compactGlossaries': s.compactGlossaries.toString(),
        'embedMedia': s.embedMedia.toString(),
        // 两个范围单选必须进快照：[mapToAnkiSettings] 重建的是一个全新
        // AnkiSettings，不在这里的字段会在切 Profile 时静默回默认值
        // （overwriteScope 原本就漏了，顺手一并补上）。
        'overwriteScope': s.overwriteScope.name,
        'duplicateScope': s.duplicateScope.name,
      };

  static AnkiSettings mapToAnkiSettings(
    Map<String, String> m,
    AnkiSettings current,
  ) {
    int? parseInt(String? v) => v == null || v.isEmpty ? null : int.tryParse(v);

    return AnkiSettings(
      selectedDeckId: parseInt(m['selectedDeckId']),
      selectedDeckName: m['selectedDeckName']?.isNotEmpty == true
          ? m['selectedDeckName']
          : null,
      selectedNoteTypeId: parseInt(m['selectedNoteTypeId']),
      selectedNoteTypeName: m['selectedNoteTypeName']?.isNotEmpty == true
          ? m['selectedNoteTypeName']
          : null,
      availableDecks: current.availableDecks,
      availableNoteTypes: current.availableNoteTypes,
      fieldMappings:
          _parseFieldMappings(m['fieldMappings'], current.fieldMappings),
      tags: m['tags'] ?? '',
      tagIncludeHibiki: m.containsKey('tagIncludeHibiki')
          ? m['tagIncludeHibiki'] == 'true'
          : true,
      tagIncludeCategory: m.containsKey('tagIncludeCategory')
          ? m['tagIncludeCategory'] == 'true'
          : true,
      allowDupes: m['allowDupes'] == 'true',
      compactGlossaries: m['compactGlossaries'] == 'true',
      embedMedia:
          m.containsKey('embedMedia') ? m['embedMedia'] == 'true' : true,
      // 旧快照没有这两个键 → 保留当前值（而不是回默认），否则一次切
      // Profile 就把用户已选的范围抹掉。
      overwriteScope: m.containsKey('overwriteScope')
          ? ankiOverwriteScopeFromName(m['overwriteScope'])
          : current.overwriteScope,
      duplicateScope: m.containsKey('duplicateScope')
          ? ankiDuplicateScopeFromName(m['duplicateScope'])
          : current.duplicateScope,
    );
  }

  /// Parses the stored fieldMappings JSON defensively. The value comes from the
  /// profile_settings DB table, which can hold malformed data (manual edit,
  /// aborted snapshot write, cross-version backup import). A single bad row
  /// must not throw and abort the entire profile-apply flow (HBK-AUDIT-043).
  static Map<String, String> _parseFieldMappings(
    String? raw,
    Map<String, String> fallback,
  ) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // Fall through to the fallback below.
    }
    return fallback;
  }
}
