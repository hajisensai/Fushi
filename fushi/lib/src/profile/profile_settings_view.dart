import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show RemoteLookupDictionaryConfig;

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
///   （顺序 / 隐藏语言 / 折叠 / 展开 / 语言覆盖 / 混合词典汉字部分开关）；服务器托管词典
///   同理：live `remote_dictionary_metadata` 目录行（参与查词的 host）换上快照里的顺序 / 开关；
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
    List<RemoteDictionary> remoteDictionaries = const <RemoteDictionary>[],
    Map<String, String> ankiSnapshot = const <String, String>{},
  }) : prefsMap = Map<String, String>.unmodifiable(prefsMap),
       ankiSnapshot = Map<String, String>.unmodifiable(ankiSnapshot),
       dictionaries = List<Dictionary>.unmodifiable(dictionaries),
       remoteDictionaries = List<RemoteDictionary>.unmodifiable(
         remoteDictionaries,
       ),
       lookupFilters = DictionaryRepository.lookupFiltersOf(
         dictionaries,
         remoteDictionaries,
       );

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

  /// 该配置快照里自己拥有的 Anki 字段（`ProfileKeys.ankiSettingsToMap` 形，未合成）；空 = 快照
  /// 没有 Anki 字段（老配置），按 live 设置。作品会话据此决定接不接管 Anki 设置。
  final Map<String, String> ankiSnapshot;

  /// 合成后的词典列表（按管理页顺序）。
  final List<Dictionary> dictionaries;

  /// 合成后的服务器托管词典（参与查词的 host，按管理页顺序）。
  final List<RemoteDictionary> remoteDictionaries;

  /// 这个配置对 [hostId] 这台 host 的词典选择（与 `DictionaryRepository.filtersForHost`
  /// 同一判据，[DictionaryRepository.remoteLookupConfigFor]）。
  RemoteLookupDictionaryConfig? filtersForHost(String hostId) =>
      DictionaryRepository.remoteLookupConfigFor(
        dictionaries: dictionaries,
        remoteDictionaries: remoteDictionaries,
        hostId: hostId,
      );

  /// 查词用的过滤与排序（与 `DictionaryRepository.lookupFilters` 同一判据）。
  final DictionaryLookupFilters lookupFilters;

  /// 查词结果缓存键的命名空间前缀：带配置 id + 本视图词典过滤的指纹。
  ///
  /// App 自己的查词缓存键（不带前缀）与它永不相撞——同一个词按 A 配置的词典集合查出的
  /// popupJson 不能被 B 配置的请求命中。指纹进键是因为同一配置的快照会变（在 B 里改了
  /// 词典顺序再切走 = 快照更新），旧键自然失效，不依赖任何写入点手动清缓存。
  late final String lookupCacheNamespace =
      'xprofile:$profileId:${lookupFilters.fingerprint}|';

  /// 只读的 Anki 设置存储：读到的是 [ankiSettings]。
  AnkiSettingsStore get ankiSettingsStore =>
      ProfileViewAnkiSettingsStore(jsonEncode(ankiSettings.toJson()));

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
