/// 配置方案（Profile）分享 JSON 的**编解码与「作为新 Profile 落库」**——app 与
/// 无头服务端共用的唯一实现。
///
/// 这份 JSON 就是「配置管理」页导出的 `<名字>.fushiprofile.json`，也是互联
/// `/api/interconnect/profile` 的载荷（见 `interconnect_profile_transfer.dart`）。
/// 以前解析 / 组装 / createNew 落库全写在 app 的 `ProfileRepository` 里，服务端要
/// 收发同一份载荷就只能再抄一份——魔数、版本判据、「哪条废弃 key 入站即拒」于是会有
/// 两个真相源。这里只收纯 DB 的部分：
///
/// * **不**含「当前活偏好 → 快照」（`snapshotCurrentSettings`）与「快照 → 活偏好」
///   （`applyProfile`）：那两步要读写 Anki 设置、词典装没装的磁盘判据与 app 内存
///   缓存，只有 app 凑得齐；
/// * **不**含出境剔凭据：判定的唯一真相源是 app 的 `PrefRedactionPolicy`，由调用方
///   在把快照行交给 [encodeProfileDocument] 之前过滤。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';

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

/// profile_settings 里「Drift 偏好」这一类的 category 值（与 app `ProfileKeys`
/// 同值，那边引用本常量）。
const String kProfileSettingCategoryPref = 'pref';

/// v63 已从 live preferences 与 Profile 副本中删除的旧全局超分键。
///
/// 每游戏真值是 `galgames.upscaling_mode`；此键只保留为输入拒绝标识，防止
/// 旧快照或旧分享 JSON 在升级后把废弃数据重新写回。
const String kObsoleteGalgameUpscalingModePrefKey =
    'galgame_magpie_upscaling_mode';

/// 解析并校验一个导出 JSON 字符串。坏文件 / 魔数不符 / 版本不兼容 / 结构非法
/// 一律抛 [ProfileImportException]（**在写 DB 之前**）。
ProfileExport parseProfileDocument(String json) {
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
      '${ProfileExport.fileType})',
    );
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
        'settings entry has non-string category/key/value',
      );
    }
    entries.add(
      ProfileSettingEntry(category: category, key: key, value: value),
    );
  }

  return ProfileExport(
    profileName: rawName,
    formatVersion: formatVersion,
    schemaVersion: schemaVersion,
    settings: entries,
  );
}

/// 组装分享 JSON（带缩进）。[settings] 必须已由调用方剔除凭据 / 设备本地 key、
/// 剥掉字体绝对路径——本函数只负责信封格式，不做任何过滤。
String encodeProfileDocument({
  required String profileName,
  required int schemaVersion,
  required List<ProfileSettingEntry> settings,
}) {
  final Map<String, dynamic> doc = <String, dynamic>{
    'type': ProfileExport.fileType,
    'formatVersion': ProfileExport.currentFormatVersion,
    'schemaVersion': schemaVersion,
    'profileName': profileName,
    'settings': <Map<String, String>>[
      for (final ProfileSettingEntry s in settings)
        <String, String>{
          'category': s.category,
          'key': s.key,
          'value': s.value,
        },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(doc);
}

/// 把一个唯一的 Profile 名衍生出来：若 [base] 已被占用，追加 ` (2)`、` (3)`…
/// 直到不冲突（`Profiles.name` 有 unique 约束，重名插入会抛）。
String uniqueProfileNameAmong(Set<String> taken, String base) {
  if (!taken.contains(base)) return base;
  int n = 2;
  while (taken.contains('$base ($n)')) {
    n++;
  }
  return '$base ($n)';
}

/// [uniqueProfileNameAmong] 的 `profiles` 表版本。
Future<String> uniqueProfileName(FushiDatabase db, String base) async {
  final List<ProfileRow> existing = await db.getAllProfiles();
  return uniqueProfileNameAmong(
    existing.map((ProfileRow p) => p.name).toSet(),
    base,
  );
}

/// 入站设置项的唯一准入判据（落 `profile_settings` 与服务端寄存共用）。
///
/// v63 只拒绝旧全局超分键的 pref 分类。不要改成过滤全部 isExcludedPref：其它
/// 排除键有各自的跨版本/设备本地语义，扩大过滤会无授权地改变旧 Profile JSON 的
/// 导入行为；同名非 pref 分类也必须保留。
bool isAcceptedProfileSettingEntry(ProfileSettingEntry e) =>
    e.category != kProfileSettingCategoryPref ||
    e.key != kObsoleteGalgameUpscalingModePrefKey;

/// 把解析出的设置项绑定到真实 profileId，构造 insert companions。
List<ProfileSettingsCompanion> profileSettingCompanions(
  List<ProfileSettingEntry> entries,
  int profileId,
) => <ProfileSettingsCompanion>[
  for (final ProfileSettingEntry e in entries)
    if (isAcceptedProfileSettingEntry(e))
      ProfileSettingsCompanion.insert(
        profileId: profileId,
        category: e.category,
        key: e.key,
        value: e.value,
      ),
];

/// 把 [export] 作为**新** Profile 落库（名取自文件，重名加后缀），返回新 id。
///
/// 不激活、不 apply：新 Profile 只是出现在列表里，要不要切过去由用户决定。
Future<int> importProfileDocumentAsNew(
  FushiDatabase db,
  ProfileExport export,
) async {
  final String name = await uniqueProfileName(db, export.profileName);
  final int now = DateTime.now().millisecondsSinceEpoch;
  final int id = await db.insertProfile(
    ProfilesCompanion.insert(name: name, createdAt: now, updatedAt: now),
  );
  await db.replaceProfileSettings(
    id,
    profileSettingCompanions(export.settings, id),
  );
  return id;
}
