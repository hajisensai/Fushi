/// 朗读声音按作品记：一本书 / 漫画朗读时用哪个声音。
///
/// 查找顺序：本书指定 → 「系列 + 本书语言」→ 全局「使用中」声音（[TtsPresetStore]）。
/// 在朗读中快速切换声音时写进这里：书属于系列就记到「系列 + 语言」（同系列同语言的
/// 其它卷一起用，换语言的版本互不影响——如日文版与台版《化物語》在同一个合集里：
/// 用户手动建的混合合集，或按语言拆组之前就建好的合集），没有系列就只记这本书。全局默认仍由「朗读声音」设置页决定。
///
/// 值都是本机声音预设 id，与 `tts_voice_presets` / `tts_active_preset_id` 同族：设备本地，
/// 不进同步 / 备份 / Profile。整张表落一个偏好键（[TtsPresetStore.mediaVoicesKey]）。
library;

import 'dart:convert';

import 'package:fushi_engine/models/content_language.dart';

/// 一次朗读所属的作品：书键、所属系列（null = 不属任何系列）与语言。
class TtsMediaVoiceScope {
  const TtsMediaVoiceScope({
    required this.bookKey,
    this.seriesKey,
    this.language,
  });

  final String bookKey;

  /// 系列身份（如 `collection:<id>`）；null = 这本书不属任何系列。
  final String? seriesKey;

  /// 本书的内容语言（BCP-47 / 自由文本均可，[contentLanguageKey] 归一）；
  /// null = 未知。
  final String? language;

  /// 归一后的语言键（未知为空串：同系列里语言未知的书共用一格）。
  String get languageKey => contentLanguageKey(language);
}

/// 声音从哪一层来。
enum TtsVoiceSource {
  /// 本书单独指定。
  book,

  /// 系列 + 语言。
  series,

  /// 全局「使用中」声音。
  defaultVoice,
}

/// 作品 → 声音预设 id 的两张表（本书、系列 × 语言）。纯数据，读写经
/// [TtsPresetStore.loadMediaVoices] / [TtsPresetStore.saveMediaVoices]。
class TtsMediaVoices {
  TtsMediaVoices({
    Map<String, String>? books,
    Map<String, Map<String, String>>? series,
  }) : books = books ?? <String, String>{},
       series = series ?? <String, Map<String, String>>{};

  /// 书键 → 预设 id。
  final Map<String, String> books;

  /// 系列身份 → 语言键（[contentLanguageKey]，未知为空串）→ 预设 id。
  final Map<String, Map<String, String>> series;

  bool get isEmpty => books.isEmpty && series.isEmpty;

  /// [scope] 按顺序可试的候选：本书 → 系列 + 语言。调用方逐个验证（预设还在、
  /// 引擎可用），都不行再用全局默认。
  List<({String presetId, TtsVoiceSource source})> candidatesFor(
    TtsMediaVoiceScope scope,
  ) {
    final String? book = books[scope.bookKey];
    final String? seriesKey = scope.seriesKey;
    final String? bySeries = seriesKey == null
        ? null
        : series[seriesKey]?[scope.languageKey];
    return <({String presetId, TtsVoiceSource source})>[
      if (book != null && book.isNotEmpty)
        (presetId: book, source: TtsVoiceSource.book),
      if (bySeries != null && bySeries.isNotEmpty)
        (presetId: bySeries, source: TtsVoiceSource.series),
    ];
  }

  /// 在 [scope] 里选定 [presetId]：有系列记到「系列 + 语言」并清掉本书的单独指定
  /// （否则系列这一层被本书挡住不生效）；没有系列记到本书。
  void assign(TtsMediaVoiceScope scope, String presetId) {
    final String? seriesKey = scope.seriesKey;
    if (seriesKey == null) {
      books[scope.bookKey] = presetId;
      return;
    }
    (series[seriesKey] ??= <String, String>{})[scope.languageKey] = presetId;
    books.remove(scope.bookKey);
  }

  /// 清掉 [scope] 的指定（本书与「系列 + 语言」两层），回到全局默认。
  void clear(TtsMediaVoiceScope scope) {
    books.remove(scope.bookKey);
    final String? seriesKey = scope.seriesKey;
    if (seriesKey == null) return;
    final Map<String, String>? byLanguage = series[seriesKey];
    if (byLanguage == null) return;
    byLanguage.remove(scope.languageKey);
    if (byLanguage.isEmpty) series.remove(seriesKey);
  }

  /// 删掉指向 [presetId] 的全部条目（声音预设被删时调）。返回是否有变化。
  bool forgetPreset(String presetId) {
    final int before =
        books.length +
        series.values.fold<int>(
          0,
          (int n, Map<String, String> m) => n + m.length,
        );
    books.removeWhere((String _, String id) => id == presetId);
    for (final Map<String, String> byLanguage in series.values) {
      byLanguage.removeWhere((String _, String id) => id == presetId);
    }
    series.removeWhere((String _, Map<String, String> m) => m.isEmpty);
    final int after =
        books.length +
        series.values.fold<int>(
          0,
          (int n, Map<String, String> m) => n + m.length,
        );
    return after != before;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'books': books,
    'series': series,
  };

  static TtsMediaVoices fromJson(Object? raw) {
    if (raw is! Map) return TtsMediaVoices();
    Map<String, String> strings(Object? value) => <String, String>{
      if (value is Map)
        for (final MapEntry<Object?, Object?> e in value.entries)
          if (e.key is String &&
              e.value is String &&
              (e.value! as String).isNotEmpty)
            e.key! as String: e.value! as String,
    };
    final Object? rawSeries = raw['series'];
    return TtsMediaVoices(
      books: strings(raw['books']),
      series: <String, Map<String, String>>{
        if (rawSeries is Map)
          for (final MapEntry<Object?, Object?> e in rawSeries.entries)
            if (e.key is String && strings(e.value).isNotEmpty)
              e.key! as String: strings(e.value),
      },
    );
  }

  String encode() => jsonEncode(toJson());

  static TtsMediaVoices decode(String raw) {
    if (raw.isEmpty) return TtsMediaVoices();
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return TtsMediaVoices();
    }
  }
}
