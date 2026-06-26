import 'dart:convert';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/media_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/profile/profile_keys.dart';
import 'package:hibiki/src/sync/backup_service.dart'
    show rebaseFontCatalogJson, rebaseFontListJson;
import 'package:hibiki/src/sync/sync_repository.dart';

/// 配置方案导入失败：文件损坏 / 类型魔数不符 / 版本不兼容 / 结构非法。
///
/// 故意在写任何 DB 之前抛出（解析 + 校验阶段），使导入对 DB 是全有或全无，
/// 一个坏文件绝不留下半个 Profile（事务零破坏）。
class ProfileImportException implements Exception {
  ProfileImportException(this.message);
  final String message;
  @override
  String toString() => 'ProfileImportException: $message';
}

/// 导入模式：新建一个 Profile（默认，重名加后缀），或覆盖一个已有 Profile。
enum ProfileImportMode { createNew, overwrite }

/// 单 Profile 导出文件的解析结果（已剔除凭据、已 A1 剥字体绝对路径）。
class ProfileExport {
  ProfileExport({
    required this.profileName,
    required this.formatVersion,
    required this.schemaVersion,
    required this.settings,
  });

  /// 文件类型魔数：辨识这是 Hibiki 配置方案导出，而非任意 JSON / 整库备份。
  static const String fileType = 'hibiki.profile';

  /// 当前导出文件格式版本。结构变化时 +1；导入按此判兼容。
  static const int currentFormatVersion = 1;

  final String profileName;
  final int formatVersion;
  final int schemaVersion;

  /// 每条 `{category, key, value}`；category ∈ {anki, pref, ...}。
  final List<ProfileSettingEntry> settings;
}

/// 单条配置项（category/key/value），对应 profile_settings 行。
class ProfileSettingEntry {
  ProfileSettingEntry({
    required this.category,
    required this.key,
    required this.value,
  });
  final String category;
  final String key;
  final String value;
}

class ProfileRepository {
  ProfileRepository(this._db, this._ankiRepo);
  final HibikiDatabase _db;
  final BaseAnkiRepository _ankiRepo;

  Future<List<ProfileRow>> getAllProfiles() => _db.getAllProfiles();

  Future<ProfileRow?> getProfileById(int id) => _db.getProfileById(id);

  Future<int> getActiveProfileId() async {
    final raw = await _db.getPref('active_profile_id');
    return raw != null ? (int.tryParse(raw) ?? -1) : -1;
  }

  Future<void> setActiveProfileId(int id) =>
      _db.setPref('active_profile_id', id.toString());

  Future<int> createProfile(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db.insertProfile(
      ProfilesCompanion.insert(
        name: name,
        createdAt: now,
        updatedAt: now,
      ),
    );
    return id;
  }

  Future<void> renameProfile(int id, String name) =>
      _db.updateProfileName(id, name);

  Future<void> deleteProfile(int id) async {
    final count = await _db.countProfiles();
    if (count <= 1) return;

    final activeId = await getActiveProfileId();
    await _db.deleteProfile(id);

    if (activeId == id) {
      final remaining = await _db.getAllProfiles();
      if (remaining.isNotEmpty) {
        await setActiveProfileId(remaining.first.id);
        await applyProfile(remaining.first.id);
      }
    }
  }

  Future<void> snapshotCurrentSettings(int profileId) async {
    // Profile ids are autoincrement (always >= 1); a non-positive id is the
    // "no active profile" sentinel (e.g. ProfileViewModel.dispose fires before
    // _load assigns a real id, so state.activeProfileId is still -1).
    // Snapshotting it would write orphan profile_settings rows / trip the FK.
    if (profileId <= 0) return;

    final entries = <ProfileSettingsCompanion>[];

    // Anki settings (SharedPreferences)
    final ankiSettings = await _ankiRepo.loadSettings();
    final ankiMap = ProfileKeys.ankiSettingsToMap(ankiSettings);
    for (final entry in ankiMap.entries) {
      entries.add(ProfileSettingsCompanion.insert(
        profileId: profileId,
        category: ProfileKeys.categoryAnki,
        key: entry.key,
        value: entry.value,
      ));
    }

    // ALL Drift prefs (excluding app-state keys)
    final allPrefs = await _db.getAllPrefs();
    for (final entry in allPrefs.entries) {
      if (ProfileKeys.isExcludedPref(entry.key)) continue;
      entries.add(ProfileSettingsCompanion.insert(
        profileId: profileId,
        category: ProfileKeys.categoryPref,
        key: entry.key,
        value: entry.value,
      ));
    }

    await _db.replaceProfileSettings(profileId, entries);
  }

  Future<void> applyProfile(int profileId) async {
    // A non-positive (sentinel) id has no snapshot rows, so the prune step
    // below would delete EVERY non-excluded live pref — silent settings wipe.
    // Ids are always >= 1, so guard the sentinel instead of nuking prefs.
    if (profileId <= 0) return;

    final rows = await _db.getProfileSettings(profileId);

    final ankiMap = <String, String>{};
    final prefMap = <String, String>{};
    for (final row in rows) {
      switch (row.category) {
        case ProfileKeys.categoryAnki:
          ankiMap[row.key] = row.value;
        case ProfileKeys.categoryPref:
          prefMap[row.key] = row.value;
        // Legacy categories from old snapshots
        case ProfileKeys.categoryDictionary:
          prefMap[row.key] = row.value;
        case ProfileKeys.categoryReader:
          // 旧快照里 reader 偏好按 MediaSource 命名空间还原；用单一真相编码器
          // 而非硬编码 `src:reader_ttu:` 猜下层私有 key 格式（[dbSourcePrefKey]）。
          prefMap[dbSourcePrefKey('reader_ttu', row.key)] = row.value;
        default:
          break;
      }
    }

    // Wrap DB writes in transaction for consistency
    await _db.transaction(() async {
      final currentPrefs = await _db.getAllPrefs();
      for (final key in currentPrefs.keys) {
        if (ProfileKeys.isExcludedPref(key)) continue;
        if (!prefMap.containsKey(key)) {
          await _db.deletePref(key);
        }
      }
      for (final entry in prefMap.entries) {
        await _db.setPref(entry.key, entry.value);
      }
      // TODO-855: a profile switch writes prefs straight through _db.setPref,
      // bypassing PreferencesRepository.setPref's version bump. Bump the
      // persisted prefs-version here (atomically, in the same transaction) so
      // the separate :popup process's warm-reuse cache detects the switch and
      // reloads on its next lookup. prefs_version is excluded from profile
      // snapshots, so it is neither pruned above nor present in prefMap. Stored
      // as a PrefCodec int to round-trip identically to the repository's bump.
      final String? rawVersion =
          currentPrefs[PreferencesRepository.prefsVersionKey];
      final int nextVersion =
          (rawVersion == null ? 0 : PrefCodec.decode<int>(rawVersion, 0)) + 1;
      await _db.setPref(
        PreferencesRepository.prefsVersionKey,
        PrefCodec.encode(nextVersion),
      );
    });

    // Anki settings (SharedPreferences)
    if (ankiMap.isNotEmpty) {
      final current = await _ankiRepo.loadSettings();
      final updated = ProfileKeys.mapToAnkiSettings(ankiMap, current);
      await _ankiRepo.saveSettings(updated);
    }
  }

  Future<int> copyProfile(int sourceId, String newName) async {
    final newId = await createProfile(newName);
    final sourceSettings = await _db.getProfileSettings(sourceId);
    final copies = sourceSettings
        .map((s) => ProfileSettingsCompanion.insert(
              profileId: newId,
              category: s.category,
              key: s.key,
              value: s.value,
            ))
        .toList();
    await _db.replaceProfileSettings(newId, copies);
    return newId;
  }

  Future<Map<String, int>> getAllMediaTypeBindings() async {
    final rows = await _db.getAllMediaTypeProfiles();
    return {for (final r in rows) r.mediaType: r.profileId};
  }

  Future<void> setMediaTypeBinding(String mediaType, int profileId) =>
      _db.setMediaTypeProfile(mediaType, profileId);

  Future<void> removeMediaTypeBinding(String mediaType) =>
      _db.deleteMediaTypeProfile(mediaType);

  Future<int?> getBookProfileId(String bookUid) async {
    final row = await _db.getBookProfile(bookUid);
    return row?.profileId;
  }

  Future<void> setBookProfile(String bookUid, int profileId) =>
      _db.setBookProfile(bookUid, profileId);

  Future<void> removeBookProfile(String bookUid) =>
      _db.deleteBookProfile(bookUid);

  Future<int> resolveProfileId({
    required String? bookUid,
    required String? mediaType,
  }) async {
    if (bookUid != null) {
      final bookProfileId = await getBookProfileId(bookUid);
      if (bookProfileId != null) return bookProfileId;
    }

    if (mediaType != null) {
      final mtRow = await _db.getMediaTypeProfile(mediaType);
      if (mtRow != null) return mtRow.profileId;
    }

    return getActiveProfileId();
  }

  // ── 导出 / 导入（单 Profile JSON 序列化）────────────────────────────

  /// LIKE 兜底匹配（小写）的凭据 key 子串。白名单
  /// [SyncRepository.deviceLocalPrefKeys] 是主防线；这里再加一道按内容形状的
  /// 兜底，使将来新增的、还没进白名单的凭据 key 也被剔除（防漏）。
  ///
  /// 注意补齐了 `private_key`（sync_sftp_private_key）和 `credential`
  /// （sync_desktop_credentials）——只匹配 password/token/secret 会漏掉这两个。
  static const List<String> _credentialSubstrings = <String>[
    'password',
    'token',
    'secret',
    'private_key',
    'credential',
  ];

  /// 判断一个 pref key 是否属于「设备本地 / 凭据」，导出时必须剔除。
  ///
  /// 主防线：白名单 [SyncRepository.deviceLocalPrefKeys]（含全部 9 个 sync
  /// 凭据 + 后端选择 + 服务器地址等设备本地配置）。
  /// 兜底：`sync_` 前缀 + 凭据形状子串（[_credentialSubstrings]）的 LIKE 扫描。
  static bool _isCredentialOrDeviceLocalPref(String key) {
    if (SyncRepository.deviceLocalPrefKeys.contains(key)) return true;
    final String lower = key.toLowerCase();
    if (!lower.startsWith('sync_')) return false;
    for (final String sub in _credentialSubstrings) {
      if (lower.contains(sub)) return true;
    }
    return false;
  }

  /// 把单个 Profile 序列化成可分享的 JSON 字符串。
  ///
  /// - 激活 Profile：先 [snapshotCurrentSettings]（autosnapshot）把当前活的
  ///   偏好写进快照再读，保证导出的是最新状态。
  /// - 非激活 Profile：直读其已有快照，**不** snapshot（否则会用当前活偏好
  ///   污染那个 Profile 的快照）。
  /// - 凭据红线：导出前按 [_isCredentialOrDeviceLocalPref] 剔除全部凭据 /
  ///   设备本地 key（白名单为主、LIKE 兜底），绝不让 base64 凭据进文件。
  /// - 字体路径（A1）：把 `font_catalog` / 旧 shadow 列表里指向本机
  ///   `custom_fonts/` 的绝对路径剥成相对（rebase 到空根），导到别的设备时
  ///   该字体文件缺失则优雅降级（条目在、文件找不到、加载器跳过），不泄漏
  ///   本机目录结构、也不会指向不存在的绝对路径。[fontsRootDirectory] 为 null
  ///   （未知字体根）时跳过剥离，原样导出。
  ///
  /// 返回带缩进的 JSON 字符串。调用方负责落盘 / 分享。
  Future<String> exportProfileToJson(
    int profileId, {
    String? fontsRootDirectory,
  }) async {
    final ProfileRow? profile = await _db.getProfileById(profileId);
    if (profile == null) {
      throw ProfileImportException('profile $profileId not found');
    }

    final int activeId = await getActiveProfileId();
    if (profileId == activeId) {
      // 激活 Profile：导出前刷一次快照，确保拿到当前活偏好。
      await snapshotCurrentSettings(profileId);
    }

    final List<ProfileSettingRow> rows =
        await _db.getProfileSettings(profileId);

    final List<Map<String, String>> settings = <Map<String, String>>[];
    for (final ProfileSettingRow row in rows) {
      // 凭据红线：唯一前置防线，剔除全部凭据 / 设备本地 key。
      if (row.category == ProfileKeys.categoryPref &&
          _isCredentialOrDeviceLocalPref(row.key)) {
        continue;
      }
      final String value = _exportFontPathStrippedValue(
        category: row.category,
        key: row.key,
        value: row.value,
        fontsRootDirectory: fontsRootDirectory,
      );
      settings.add(<String, String>{
        'category': row.category,
        'key': row.key,
        'value': value,
      });
    }

    final Map<String, dynamic> doc = <String, dynamic>{
      'type': ProfileExport.fileType,
      'formatVersion': ProfileExport.currentFormatVersion,
      'schemaVersion': _db.schemaVersion,
      'profileName': profile.name,
      'settings': settings,
    };
    return const JsonEncoder.withIndent('  ').convert(doc);
  }

  /// A1 字体路径剥离：把字体配置 JSON 里指向本机 `custom_fonts/` 的绝对路径
  /// 剥成相对（rebase 到空根）。非字体 key 原样返回。
  String _exportFontPathStrippedValue({
    required String category,
    required String key,
    required String value,
    required String? fontsRootDirectory,
  }) {
    if (fontsRootDirectory == null) return value;
    if (category != ProfileKeys.categoryPref) return value;
    if (key == _fontCatalogPrefKey) {
      return rebaseFontCatalogJson(value, fontsRootDirectory, '');
    }
    if (_legacyFontPrefKeys.contains(key)) {
      return rebaseFontListJson(value, fontsRootDirectory, '');
    }
    return value;
  }

  /// 字体配置的持久化 key（与 backup_service 同源；见
  /// `BackupService._fontCatalogPrefKey` / `_legacyFontPrefKeys`）。
  static const String _fontCatalogPrefKey = 'src:reader_ttu:font_catalog';
  static const List<String> _legacyFontPrefKeys = <String>[
    'src:reader_ttu:custom_fonts',
    'src:reader_ttu:app_ui_fonts',
    'src:reader_ttu:dict_fonts',
  ];

  /// 解析并校验一个导出 JSON 字符串。坏文件 / 魔数不符 / 版本不兼容 / 结构非法
  /// 一律抛 [ProfileImportException]（**在写 DB 之前**）。
  ProfileExport parseProfileExport(String json) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (e) {
      throw ProfileImportException('not valid JSON: $e');
    }
    if (decoded is! Map) {
      throw ProfileImportException('top-level value is not an object');
    }
    final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);

    if (map['type'] != ProfileExport.fileType) {
      throw ProfileImportException(
          'unexpected file type: ${map['type']} (expected '
          '${ProfileExport.fileType})');
    }
    final Object? rawFormat = map['formatVersion'];
    final int formatVersion = rawFormat is int ? rawFormat : -1;
    if (formatVersion <= 0 ||
        formatVersion > ProfileExport.currentFormatVersion) {
      throw ProfileImportException('unsupported format version: $rawFormat');
    }
    final Object? rawName = map['profileName'];
    if (rawName is! String || rawName.trim().isEmpty) {
      throw ProfileImportException('missing or empty profileName');
    }
    final Object? rawSettings = map['settings'];
    if (rawSettings is! List) {
      throw ProfileImportException('settings is not a list');
    }
    final Object? rawSchema = map['schemaVersion'];
    final int schemaVersion = rawSchema is int ? rawSchema : 0;

    final List<ProfileSettingEntry> entries = <ProfileSettingEntry>[];
    for (final dynamic e in rawSettings) {
      if (e is! Map) {
        throw ProfileImportException('settings entry is not an object');
      }
      final Object? category = e['category'];
      final Object? key = e['key'];
      final Object? value = e['value'];
      if (category is! String || key is! String || value is! String) {
        throw ProfileImportException(
            'settings entry has non-string category/key/value');
      }
      entries.add(ProfileSettingEntry(
        category: category,
        key: key,
        value: value,
      ));
    }

    return ProfileExport(
      profileName: rawName,
      formatVersion: formatVersion,
      schemaVersion: schemaVersion,
      settings: entries,
    );
  }

  /// 把一个唯一的 Profile 名衍生出来：若 [base] 已被占用，追加 ` (2)`、` (3)`…
  /// 直到不冲突（`Profiles.name` 有 unique 约束，重名插入会抛）。
  Future<String> _uniqueProfileName(String base) async {
    final List<ProfileRow> existing = await _db.getAllProfiles();
    final Set<String> taken = existing.map((ProfileRow p) => p.name).toSet();
    if (!taken.contains(base)) return base;
    int n = 2;
    while (taken.contains('$base ($n)')) {
      n++;
    }
    return '$base ($n)';
  }

  /// 从导出 JSON 导回一个 Profile。
  ///
  /// 解析 + 校验阶段任何问题都在写 DB 前抛 [ProfileImportException]（事务零
  /// 破坏）。校验通过后：
  /// - [ProfileImportMode.createNew]（默认）：新建一个 Profile，名取自文件，
  ///   重名自动加后缀。
  /// - [ProfileImportMode.overwrite]：用文件内容覆盖 [targetProfileId] 指向的
  ///   已有 Profile 的设置（[replaceProfileSettings] 已是事务）；若覆盖的是当前
  ///   激活 Profile，调用方需再 [applyProfile] 让其立即生效。
  ///
  /// 返回写入的 Profile id。
  Future<int> importProfileFromJson(
    String json, {
    ProfileImportMode mode = ProfileImportMode.createNew,
    int? targetProfileId,
  }) async {
    final ProfileExport export = parseProfileExport(json);

    switch (mode) {
      case ProfileImportMode.createNew:
        final String name = await _uniqueProfileName(export.profileName);
        final int newId = await createProfile(name);
        await _db.replaceProfileSettings(
          newId,
          _companionsFor(export.settings, newId),
        );
        return newId;
      case ProfileImportMode.overwrite:
        if (targetProfileId == null) {
          throw ProfileImportException(
              'overwrite mode requires targetProfileId');
        }
        final ProfileRow? target = await _db.getProfileById(targetProfileId);
        if (target == null) {
          throw ProfileImportException(
              'overwrite target $targetProfileId not found');
        }
        await _db.replaceProfileSettings(
          targetProfileId,
          _companionsFor(export.settings, targetProfileId),
        );
        return targetProfileId;
    }
  }

  /// 把解析出的设置项绑定到真实 profileId，构造 insert companions。
  List<ProfileSettingsCompanion> _companionsFor(
    List<ProfileSettingEntry> entries,
    int profileId,
  ) =>
      entries
          .map((ProfileSettingEntry e) => ProfileSettingsCompanion.insert(
                profileId: profileId,
                category: e.category,
                key: e.key,
                value: e.value,
              ))
          .toList();

  Future<void> ensureDefaultProfile() async {
    final existing = await _db.getAllProfiles();
    if (existing.isEmpty) {
      final id = await createProfile('Default');
      await setActiveProfileId(id);
      await snapshotCurrentSettings(id);
      return;
    }

    final activeId = await getActiveProfileId();
    final valid = existing.any((p) => p.id == activeId);
    if (!valid) {
      await setActiveProfileId(existing.first.id);
      await applyProfile(existing.first.id);
    }
  }
}
