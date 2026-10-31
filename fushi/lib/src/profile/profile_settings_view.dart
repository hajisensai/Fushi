import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// 反馈 biLEesNqWb：某个配置（Profile）的**只读设置视图**。
///
/// 浏览器扩展可以选一个与 App 当前激活配置不同的配置（或命中「浏览器」媒体类型绑定），
/// 它的查词 / 制卡 / 查重 / 单词音频 / 在 Anki 中打开都要按那个配置处理，同时**不切换**
/// App 的激活配置、不改任何全局状态。视图就是「如果现在切到这个配置，会生效的整份设置」：
///
/// * 偏好 = 本机设备本地键（[ProfileKeys.isExcludedPref]，如模块开关 / 界面语言 / 凭据，
///   本来就不随配置走）取 live 值 + 其余键取该配置 `profile_settings` 快照里的值；
/// * 词典 = live `dictionary_metadata` 行（装了哪些是全局事实），换上快照里配置拥有的列
///   （顺序 / 隐藏语言 / 折叠 / 展开 / 语言覆盖 / 混合词典汉字部分开关）；
/// * Anki = live 设置（连接地址等设备本地字段）叠上快照里配置拥有的字段（牌组 / 笔记类型 /
///   字段映射 / 标签 / 查重范围 ……），与 `ProfileRepository.applyProfile` 同一套合成规则。
///
/// 视图由 `ProfileRepository.loadSettingsView` 构造；所有写入口都拒绝（[prefs] 写入抛
/// [UnsupportedError]，[ankiSettingsStore] 只改自己的内存副本）。
class ProfileSettingsView {
  ProfileSettingsView({
    required this.profileId,
    required this.profileName,
    required Map<String, String> prefsMap,
    required this.prefs,
    required this.ankiSettings,
    required List<Dictionary> dictionaries,
  }) : prefsMap = Map<String, String>.unmodifiable(prefsMap),
       dictionaries = List<Dictionary>.unmodifiable(dictionaries),
       lookupFilters = DictionaryRepository.lookupFiltersOf(dictionaries);

  /// 视图对应的配置 id。
  final int profileId;

  /// 配置名（只用于诊断 / 日志）。
  final String profileName;

  /// 合成后的整份偏好原始编码值（`PrefCodec` 编码，键同 `preferences` 表）。
  final Map<String, String> prefsMap;

  /// [prefsMap] 的只读 [PreferencesRepository]（全部 getter 可用，写入抛错）。
  final PreferencesRepository prefs;

  /// 合成后的 Anki 设置。
  final AnkiSettings ankiSettings;

  /// 合成后的词典列表（按管理页顺序）。
  final List<Dictionary> dictionaries;

  /// 查词用的过滤与排序（与 `DictionaryRepository.lookupFilters` 同一判据）。
  final DictionaryLookupFilters lookupFilters;

  /// 查词结果缓存键的命名空间前缀：带配置 id + 本视图词典过滤的指纹。
  ///
  /// App 自己的查词缓存键（不带前缀）与它永不相撞——同一个词按 A 配置的词典集合查出的
  /// popupJson 不能被 B 配置的请求命中。指纹进键是因为同一配置的快照会变（在 B 里改了
  /// 词典顺序再切走 = 快照更新），旧键自然失效，不依赖任何写入点手动清缓存。
  late final String lookupCacheNamespace =
      'xprofile:$profileId:${_filtersFingerprint(lookupFilters)}|';

  /// 只读的 Anki 设置存储：读到的是 [ankiSettings]。
  AnkiSettingsStore get ankiSettingsStore =>
      ProfileViewAnkiSettingsStore(jsonEncode(ankiSettings.toJson()));

  static String _filtersFingerprint(DictionaryLookupFilters filters) {
    final List<String> hidden = filters.hiddenDictionaryNames.toList()..sort();
    final String raw =
        '${hidden.join('\u0000')}\u0001${filters.termDictionaryOrder.join('\u0000')}';
    // FNV-1a 32 位 + 原串长度 + 两个条目数：哈希冲突会让两套过滤共用一个缓存键，
    // 拼上长度与条目数后要同时撞上四者才会串结果。
    int hash = 0x811c9dc5;
    for (final int unit in raw.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '${hash.toRadixString(16)}.${raw.length}.'
        '${hidden.length}.${filters.termDictionaryOrder.length}';
  }
}

/// [ProfileSettingsView] 的 Anki 设置存储：读回视图里合成好的设置 JSON。
///
/// `BaseAnkiRepository.readSettingsJson` 的载入期迁移（旧别名改写 / MiscInfo 补片段时间）
/// 命中时会回写存储——这里只改本实例的内存副本，**不触达任何持久层**：视图对应的配置
/// 不是激活配置，它的真值在 `profile_settings` 快照里，下次切到它时由 App 自己的仓库
/// 照常迁移落盘。
class ProfileViewAnkiSettingsStore implements AnkiSettingsStore {
  ProfileViewAnkiSettingsStore(this._json);

  String _json;

  @override
  Future<String?> read() async => _json;

  @override
  Future<void> write(String json) async {
    _json = json;
  }
}
