import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi_engine/profile/profile_document.dart'
    show
        kObsoleteGalgameUpscalingModePrefKey,
        kProfileSettingCategoryPref,
        kProfileSettingCategoryRemoteDictionaryMeta;
import 'package:fushi/src/prefs/fushi_pref_registry.dart';

class ProfileKeys {
  ProfileKeys._();

  static const String categoryAnki = 'anki';
  static const String categoryPref = kProfileSettingCategoryPref;

  /// v63 已从 live preferences 与 Profile 副本中删除的旧全局超分键。
  ///
  /// 每游戏真值是 `galgames.upscaling_mode`；此键只保留为输入拒绝标识，防止
  /// 旧快照或旧分享 JSON 在升级后把废弃数据重新写回。
  static const String obsoleteGalgameUpscalingModePrefKey =
      kObsoleteGalgameUpscalingModePrefKey;

  /// TODO-1077: per-profile snapshot of the `dictionary_metadata` Drift table
  /// (enable list / order / formatKey / type / hidden+collapsed languages /
  /// metadata). This is a NEW category, distinct from the legacy pref-style
  /// [categoryDictionary] below — that one only ever carried old v1 pref keys
  /// and must not be reused for the metadata-table snapshot. One
  /// profile_settings row per dictionary: key = dictionary name, value = the
  /// JSON blob produced by [ProfileRepository]'s dictionary-meta serializer.
  static const String categoryDictionaryMeta = 'dictionary_meta';

  /// v153：服务器托管词典（`remote_dictionary_metadata`）里配置拥有的两列（顺序 /
  /// 开关）的快照，与 [categoryDictionaryMeta] 同一次快照 / 同一个应用事务。一行一本：
  /// key = `<hostId>/<真名>`，value = `{"order", "hidden"}`（格式见
  /// [kProfileSettingCategoryRemoteDictionaryMeta]）。
  static const String categoryRemoteDictionaryMeta =
      kProfileSettingCategoryRemoteDictionaryMeta;

  // Legacy categories (pre-v2 snapshots stored dictionary/reader separately)
  static const String categoryDictionary = 'dictionary';
  static const String categoryReader = 'reader';

  /// [key] 是否**不**随 Profile 走：不写进快照、切 Profile 时不从快照读回、也不被剪枝。
  ///
  /// 从偏好键登记表派生（[kFushiPrefRegistry]，声明了 `profileScoped: false` 的键与键族，
  /// 外加名字像凭据的形状兜底）：设备本地 / 凭据（不出境，`PrefRedactionPolicy` 同一张表）、
  /// 本安装状态（首启、新手引导、本版新内容、一次性提示与迁移标记、prefs 版本号）、这台
  /// 设备的界面布局与网络 / 更新通道、按条目的内容与播放状态（有声书位置 / 倍速、书名改名、
  /// 扫描索引、页签顺序……）。
  ///
  /// 快照的写（snapshot）、读（apply 的 restore map）与剪枝（apply 的 prune loop）三处都走
  /// 这个谓词：一处收敛即三处生效。存量快照里已有的这类行由读侧过滤失效，无需 schema 迁移。
  /// 默认（未登记的键）随 Profile 走；漏登一个本机状态键的后果是切到它落地前建的老 Profile
  /// 时被剪掉（BUG-3754 / BUG-1019 那一类）——所以新增这类键时在它所属域的登记里声明策略。
  static bool isExcludedPref(String key) =>
      !kFushiPrefRegistry.policyOf(key).profileScoped;

  static Map<String, String> ankiSettingsToMap(AnkiSettings s) => {
    'selectedDeckId': s.selectedDeckId?.toString() ?? '',
    'selectedDeckName': s.selectedDeckName ?? '',
    'selectedNoteTypeId': s.selectedNoteTypeId?.toString() ?? '',
    'selectedNoteTypeName': s.selectedNoteTypeName ?? '',
    'fieldMappings': jsonEncode(s.fieldMappings),
    'tags': s.tags,
    'tagIncludeHibiki': s.tagIncludeHibiki.toString(),
    'tagIncludeCategory': s.tagIncludeCategory.toString(),
    'tagNestTitleUnderCategory': s.tagNestTitleUnderCategory.toString(),
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
    String? nonEmpty(String? v) => v?.isNotEmpty == true ? v : null;

    // 只覆盖快照拥有的字段（[ankiSettingsToMap] 那几项），其余一律保留当前值：
    // 连接状态与后端选择（设备本地）、Lapis 样式、媒体去重、自动重排、批量制卡……
    // 在 JSON 层合并而不是逐个列字段——此前这里从头构造一个新 AnkiSettings，
    // 没列到的字段在切 Profile 时静默回默认值（Lapis 自定义 CSS、自动重排开关都会丢），
    // 以后新加的字段也会重蹈覆辙。
    return AnkiSettings.fromJson(<String, dynamic>{
      ...current.toJson(),
      'selectedDeckId': parseInt(m['selectedDeckId']),
      'selectedDeckName': nonEmpty(m['selectedDeckName']),
      'selectedNoteTypeId': parseInt(m['selectedNoteTypeId']),
      'selectedNoteTypeName': nonEmpty(m['selectedNoteTypeName']),
      'fieldMappings': _parseFieldMappings(
        m['fieldMappings'],
        current.fieldMappings,
      ),
      'tags': m['tags'] ?? '',
      'tagIncludeHibiki': m.containsKey('tagIncludeHibiki')
          ? m['tagIncludeHibiki'] == 'true'
          : true,
      'tagIncludeCategory': m.containsKey('tagIncludeCategory')
          ? m['tagIncludeCategory'] == 'true'
          : true,
      'tagNestTitleUnderCategory': m['tagNestTitleUnderCategory'] == 'true',
      'allowDupes': m['allowDupes'] == 'true',
      'compactGlossaries': m['compactGlossaries'] == 'true',
      'embedMedia': m.containsKey('embedMedia')
          ? m['embedMedia'] == 'true'
          : true,
      // 旧快照没有这两个键 → 保留当前值（而不是回默认），否则一次切
      // Profile 就把用户已选的范围抹掉。
      if (m.containsKey('overwriteScope'))
        'overwriteScope': m['overwriteScope'],
      if (m.containsKey('duplicateScope'))
        'duplicateScope': m['duplicateScope'],
    });
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
          (dynamic k, dynamic v) => MapEntry(k.toString(), v.toString()),
        );
      }
    } catch (_) {
      // Fall through to the fallback below.
    }
    return fallback;
  }
}
