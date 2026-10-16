import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 查词弹窗渲染一份结果时要的**词典侧资源**：词典自带 CSS、词典媒体（外字 / 音调图
/// / 词典脚本）与单词发音。
///
/// 判据只有一条：**结果来自哪台设备，就用哪台设备的资源**。本机结果走本机引擎
/// （宿主不注入，WebView 走 `FushiDicts` 老路径）；结果来自已配对电脑时（手机字幕
/// 遥控器）宿主注入 [RemoteDictionaryPopupResources]，弹窗的样式注入、媒体拦截与
/// ♪ 都改问那台电脑——本机可能根本没装这部词典，装了同名的也可能是另一个版本。
///
/// 由宿主经 `DictionaryPageMixin.popupResourceSource` 注入，**不是**全局开关：同一
/// 进程里别的查词表面照旧用本机资源。
abstract interface class DictionaryPopupResourceSource {
  /// 已取回的词典样式（词典名 → CSS）。WebView 推送结果时同步读取并整表替换
  /// `window.dictionaryStyles`；内容变化时必须返回**新的** Map 实例（按身份去重）。
  Map<String, String> get dictionaryStyles;

  /// 词典媒体文件；取不到返回 null（WebView 回 404，图片降级为 alt）。
  Future<DictionaryPopupMedia?> mediaFile(String dictionary, String path);

  /// 单词发音的可播放引用（URL / 本地文件路径）；没有返回 null。
  Future<String?> wordAudioRef(String expression, String reading);
}

/// [DictionaryPopupResourceSource.mediaFile] 的结果。
class DictionaryPopupMedia {
  const DictionaryPopupMedia({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

/// 结果来自已配对电脑时的资源源：样式整套取一次（之后只在结果里出现没见过的词典名
/// 时重取），媒体按 (词典, 路径) 有界缓存并合并并发请求，发音直接转问那台电脑。
///
/// 网络细节（钉住设备、证书指纹、凭据）全在注入的三个函数里——本类只管缓存与去重，
/// 这样它可以脱离真实互联单测。
class RemoteDictionaryPopupResources implements DictionaryPopupResourceSource {
  RemoteDictionaryPopupResources({
    required Future<Map<String, String>> Function() fetchStyles,
    required Future<DictionaryPopupMedia?> Function(
      String dictionary,
      String path,
    )
    fetchMedia,
    required Future<String?> Function(String expression, String reading)
    fetchWordAudio,
    this.mediaCacheMaxBytes = 16 * 1024 * 1024,
  }) : _fetchStyles = fetchStyles,
       _fetchMedia = fetchMedia,
       _fetchWordAudio = fetchWordAudio;

  final Future<Map<String, String>> Function() _fetchStyles;
  final Future<DictionaryPopupMedia?> Function(String, String) _fetchMedia;
  final Future<String?> Function(String, String) _fetchWordAudio;

  /// 媒体缓存的总字节上限（超出按最久未用淘汰）。
  final int mediaCacheMaxBytes;

  Map<String, String> _styles = const <String, String>{};
  bool _stylesLoaded = false;

  /// 上一次整表拉取时**不在**结果里的词典名：同名再出现不重复拉（对端就是没给它
  /// 配样式，重拉也一样）。
  final Set<String> _knownWithoutStyle = <String>{};
  Future<void>? _stylesInFlight;

  final LinkedHashMap<String, DictionaryPopupMedia> _media =
      LinkedHashMap<String, DictionaryPopupMedia>();
  int _mediaBytes = 0;
  final Map<String, Future<DictionaryPopupMedia?>> _mediaInFlight =
      <String, Future<DictionaryPopupMedia?>>{};

  @override
  Map<String, String> get dictionaryStyles => _styles;

  /// 已收到 host 按 `stylesRevision` 门控下发的整表（[adoptHostStyles]）：指纹协议
  /// 本身就是权威的，[prefetchStyles] 不再另走样式端点。
  bool _revisionGated = false;

  /// BUG-3425：采用查词回包随附的 host 词典样式（`FushiRemoteLookupClient
  /// .hostDictionaryStyles`）。同一实例重复传入不算变化——WebView 按身份去重，指纹
  /// 不变期间就不会重注入。
  void adoptHostStyles(Map<String, String> styles) {
    _revisionGated = true;
    _stylesLoaded = true;
    if (identical(styles, _styles)) return;
    _styles = styles;
  }

  /// 结果渲染前调：首查拉整套样式；之后只有结果里出现了既不在样式表、也没确认过
  /// 「对端没给它样式」的词典名才重拉（对端会话中途导入了新词典）。
  ///
  /// 失败照抛——调用方决定怎么报（样式缺了只是难看，不该挡住查词结果）。
  Future<void> prefetchStyles(DictionarySearchResult result) {
    final Set<String> names = <String>{
      for (final DictionaryEntry entry in result.entries)
        if (entry.dictionaryName.isNotEmpty) entry.dictionaryName,
      for (final FushiKanjiResult kanji in result.kanjiResults)
        if (kanji.dictName.isNotEmpty) kanji.dictName,
    };
    final bool unknown = names.any(
      (String name) =>
          !_styles.containsKey(name) && !_knownWithoutStyle.contains(name),
    );
    if (_revisionGated || (_stylesLoaded && !unknown)) {
      return Future<void>.value();
    }
    return _stylesInFlight ??= _loadStyles(
      names,
    ).whenComplete(() => _stylesInFlight = null);
  }

  Future<void> _loadStyles(Set<String> requested) async {
    final Map<String, String> fetched = await _fetchStyles();
    _stylesLoaded = true;
    _knownWithoutStyle.addAll(
      requested.where((String name) => !fetched.containsKey(name)),
    );
    // 新实例：WebView 按身份判断要不要重注入。
    _styles = Map<String, String>.unmodifiable(fetched);
  }

  @override
  Future<DictionaryPopupMedia?> mediaFile(String dictionary, String path) {
    final String key = '$dictionary\u0001$path';
    final DictionaryPopupMedia? cached = _media.remove(key);
    if (cached != null) {
      _media[key] = cached; // 移到最近使用端。
      return Future<DictionaryPopupMedia?>.value(cached);
    }
    return _mediaInFlight[key] ??= _fetchMedia(dictionary, path)
        .then((DictionaryPopupMedia? media) {
          if (media != null) _remember(key, media);
          return media;
        })
        // 块体：箭头体会把被移除的那个 Future（就是本链自己）交还给
        // whenComplete，它会等它完成——自己等自己，永远挂住。
        .whenComplete(() {
          _mediaInFlight.remove(key);
        });
  }

  void _remember(String key, DictionaryPopupMedia media) {
    if (media.bytes.length > mediaCacheMaxBytes) return;
    _media[key] = media;
    _mediaBytes += media.bytes.length;
    while (_mediaBytes > mediaCacheMaxBytes && _media.isNotEmpty) {
      final String oldest = _media.keys.first;
      _mediaBytes -= _media.remove(oldest)!.bytes.length;
    }
  }

  @override
  Future<String?> wordAudioRef(String expression, String reading) =>
      _fetchWordAudio(expression, reading);
}
