/// 词典类型、混合词典「汉字部分」的元数据判据与 FFI 引擎分桶的**唯一实现**。
///
/// 纯 Dart（零 Flutter）：app（`AppModel` 的引擎装载）与无头服务端
/// （`fushi_server` 的 `ServerDictionaryHost`）共用这一份，经
/// `fushi_dictionary_core.dart` 导出。两边以前各写一份分桶规则，混合词典的汉字
/// 部分有了独立开关后服务端那份就落后了（仍按整本 hidden 装载，BUG-3571）。
library;

enum DictionaryType { term, frequency, pitch, kanji }

/// 按持久化的类型名（`dictionary_metadata.type`）取 [DictionaryType]。
/// 未知 / 空串按 term（与历来的装载语义一致：未知类型当术语词典装）。
DictionaryType dictionaryTypeFromName(String name) {
  for (final DictionaryType type in DictionaryType.values) {
    if (type.name == name) return type;
  }
  return DictionaryType.term;
}

/// 词典 metadata：这本 term 词典的 zip 里还带了 kanji_bank（混合词典，如
/// 附汉字表的国語辞典），值恒为 `'true'`。导入时由 native 的 kanji 计数决定，启动
/// 期类型自愈也会补上。带这个键的 term 词典同时进汉字桶。
const String kDictHasKanjiKey = 'hasKanji';

/// 词典 metadata：混合词典的**汉字部分**被用户在「汉字」分区关掉（`'true'`）。
///
/// 混合词典在词典管理里同时出现在「术语」与「汉字」两个分区（与 Hoshi Reader 一致），
/// 两边的开关与排序各管各的：术语部分走 hiddenLanguages / order，汉字部分走这个键与
/// [kDictKanjiOrderKey]。共用一份状态的话，在汉字分区里拖一下就会把它在术语分区的
/// 位置一起改掉。
const String kDictKanjiHiddenKey = 'kanjiHidden';

/// 词典 metadata：混合词典的汉字部分在「汉字」分区里的位置（十进制整数串）。
///
/// **缺省时退回这本词典在「术语」分区的 order**（既定行为）：用户还没在「汉字」分区
/// 拖动过它之前，它在汉字分区的位置跟着术语分区走——在「术语」分区重排会顺带改变它
/// 在汉字分区的相对位置。第一次在「汉字」分区重排（管理页拖动 / 上下移、CLI
/// `kanjiPosition`）时整个分区的位置一次性写下，此后两边互不影响。不在首次「打开」
/// 汉字分区时固化：那等于一次没有用户意图的写库（还会触发引擎重载），而缺省语义下
/// 打开前后看到的顺序本来就一样。
const String kDictKanjiOrderKey = 'kanjiOrder';

/// 混合词典汉字部分用户设置的键（[kDictKanjiHiddenKey] / [kDictKanjiOrderKey]）。
const List<String> kDictKanjiPartSettingKeys = <String>[
  kDictKanjiHiddenKey,
  kDictKanjiOrderKey,
];

/// [metadata] 里混合词典汉字部分的用户设置（只取 [kDictKanjiPartSettingKeys]）。
Map<String, String> kanjiPartSettingsIn(Map<String, String> metadata) =>
    <String, String>{
      for (final String key in kDictKanjiPartSettingKeys)
        if (metadata[key] != null) key: metadata[key]!,
    };

/// 类型为 [type]、metadata 为 [metadata] 的词典是否是混合词典（term + 内附汉字）。
bool hasEmbeddedKanjiIn(DictionaryType type, Map<String, String> metadata) =>
    type == DictionaryType.term && metadata[kDictHasKanjiKey] == 'true';

/// 混合词典的汉字部分是否被关掉（[kDictKanjiHiddenKey]）。
bool isKanjiPartHiddenIn(Map<String, String> metadata) =>
    metadata[kDictKanjiHiddenKey] == 'true';

/// 词典在「汉字」分区里的排序键：混合词典取 [kDictKanjiOrderKey]（缺省退回
/// [order]，见该键的说明），纯 kanji 词典就是 [order]。
int kanjiSectionOrderIn(
  DictionaryType type,
  Map<String, String> metadata,
  int order,
) => hasEmbeddedKanjiIn(type, metadata)
    ? int.tryParse(metadata[kDictKanjiOrderKey] ?? '') ?? order
    : order;

/// 一条词典在 FFI 引擎分桶时需要的信息。
typedef DictPathEntry = ({
  DictionaryType type,
  String path,
  bool exists,
  // 术语 / 频率 / 音调 / 纯 kanji 词典自身的开关（hiddenLanguages）。混合词典的
  // [hidden] 只管它的术语部分。
  bool hidden,
  // TODO-622: a term dictionary that also contains kanji records (a mixed
  // JA-JA 国語辞典) carries metadata['hasKanji']=='true'. Such an entry is
  // routed into the kanji bucket too, so add_kanji_dict sees it.
  bool hasKanji,
  // 混合词典汉字部分的开关（[isKanjiPartHiddenIn]），与 [hidden] 互不影响。
  bool kanjiHidden,
  // 在「汉字」分区的位置（[kanjiSectionOrderIn]）。汉字桶按它排，引擎返回的汉字卡
  // 顺序就是用户在分区里排的顺序。
  int kanjiOrder,
});

/// 把一条 `dictionary_metadata` 行的字段换成 [DictPathEntry]，判据全走上面的
/// 函数。app 与服务端从不同的数据形态（`Dictionary` 对象 / DB 行）进来，都在这里
/// 汇成同一份分桶输入。
DictPathEntry dictPathEntryOf({
  required DictionaryType type,
  required String path,
  required bool exists,
  required bool hidden,
  required Map<String, String> metadata,
  required int order,
}) => (
  type: type,
  path: path,
  exists: exists,
  hidden: hidden,
  hasKanji: hasEmbeddedKanjiIn(type, metadata),
  kanjiHidden: isKanjiPartHiddenIn(metadata),
  kanjiOrder: kanjiSectionOrderIn(type, metadata, order),
);

/// 把词典分桶成 FFI 引擎要的四组 path（term/freq/pitch/kanji）的单一真相。
///
/// 隐藏（被用户关掉）的词典**一律**不进引擎，四种类型同一规则。freq/pitch/kanji 没有
/// 渲染期隐藏过滤，进了就会直接冒出来（BUG-177 / TODO-094 S4）；term 以前故意仍进桶、
/// 靠渲染期过滤，但引擎在 Dart 过滤**之前**就按最长匹配排序并截断到 maxResults——
/// 关掉的词典的长匹配会把可见词典的结果挤出 top-N，且每条新输出路径都得记得再滤一遍
/// （BUG-419 / TODO-865 / BUG-2997 都是漏滤）。BUG-3454：源头不装载。不存在的目录跳过。
///
/// [entries] 的先后是 term / freq / pitch 桶的顺序；汉字桶按 kanjiOrder 稳定排序
/// （同序按 [entries] 先后），与词典管理页「汉字」分区的顺序一致。
({List<String> term, List<String> freq, List<String> pitch, List<String> kanji})
bucketDictPaths(List<DictPathEntry> entries) {
  final List<String> term = <String>[];
  final List<String> freq = <String>[];
  final List<String> pitch = <String>[];
  final List<({int order, int index, String path})> kanji =
      <({int order, int index, String path})>[];
  for (int i = 0; i < entries.length; i++) {
    final DictPathEntry e = entries[i];
    if (!e.exists) continue;
    switch (e.type) {
      case DictionaryType.term:
        if (!e.hidden) term.add(e.path);
      case DictionaryType.kanji:
        if (!e.hidden) {
          kanji.add((order: e.kanjiOrder, index: i, path: e.path));
        }
      case DictionaryType.frequency:
        if (!e.hidden) freq.add(e.path);
      case DictionaryType.pitch:
        if (!e.hidden) pitch.add(e.path);
    }
    // TODO-622: a mixed dictionary (type==term but containing kanji records)
    // must be registered in BOTH the term and kanji buckets so word lookup and
    // single-character kanji lookup both hit. query_kanji has a type+char double
    // guard (query.cpp), so a pure term dict (hasKanji==false) is never added
    // here and a registered mixed dict produces zero false kanji hits. Its kanji
    // part is switched by kanjiHidden, independent of the term part's hidden
    // (kanji bucket has no render-time hide filter).
    if (e.type == DictionaryType.term && e.hasKanji && !e.kanjiHidden) {
      kanji.add((order: e.kanjiOrder, index: i, path: e.path));
    }
  }
  kanji.sort(
    (
      ({int order, int index, String path}) a,
      ({int order, int index, String path}) b,
    ) => a.order != b.order
        ? a.order.compareTo(b.order)
        : a.index.compareTo(b.index),
  );
  return (
    term: term,
    freq: freq,
    pitch: pitch,
    kanji: <String>[
      for (final ({int order, int index, String path}) k in kanji) k.path,
    ],
  );
}
