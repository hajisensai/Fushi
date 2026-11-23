/// 一本书 / 一部漫画朗读时的「作品身份」（[TtsMediaVoiceScope]）：书键 + 系列 + 语言。
///
/// 系列与有声书制作台同一口径（[resolveSeriesKey]：制作台里显式关联的系列 → 书架
/// 合集；显式「不归入系列」的书没有系列），所以制作台里看到的系列与朗读记声音用的
/// 系列是同一个。语言由调用方给：小说阅读器开书时已解析好（本书语言 > 全局默认
/// 内容语言），漫画阅读器用 [ttsMediaContentLanguage] 现取。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/models/content_language.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';

/// [bookKey] 的作品身份；[language] 是本书的内容语言（null = 未知）。
Future<TtsMediaVoiceScope> resolveTtsMediaVoiceScope(
  AudioProductionHost host,
  String bookKey, {
  required String? language,
}) async => TtsMediaVoiceScope(
  bookKey: bookKey,
  seriesKey: await resolveSeriesKey(host, bookKey),
  language: language,
);

/// 书 / 漫画（同在 `epub_books`）的内容语言：本书手动指定或导入回填的语言 >
/// [globalDefault]（全局默认内容语言）。漫画的语言列多半为空（CBZ / 图片包没有语言
/// 声明），这时就是全局默认。
Future<String?> ttsMediaContentLanguage(
  FushiDatabase database,
  String bookKey, {
  required String? globalDefault,
}) async {
  final EpubBookRow? row = await database.getEpubBook(bookKey);
  return resolveContentLanguage(
    explicit: row?.language,
    globalDefault: globalDefault,
  );
}
