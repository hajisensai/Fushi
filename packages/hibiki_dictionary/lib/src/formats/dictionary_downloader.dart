import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

enum DictionaryCategory {
  jaEn,
  jaJa,
  jaOther,
  kanji,
  frequency,
  names,
  supplementary,
}

class RecommendedDictionary {
  const RecommendedDictionary({
    required this.name,
    required this.url,
    required this.description,
    required this.matchPrefix,
    required this.category,
    required this.sizeEstimate,
    this.langCode,
  });

  final String name;
  final String url;
  final String description;
  final String matchPrefix;
  final DictionaryCategory category;
  final String sizeEstimate;

  /// ISO 639-1 code for language-based auto-selection.
  /// e.g. 'en' for JMdict English, 'de' for JMdict German.
  final String? langCode;
}

const String _jmdictBase =
    'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download';
const String _marvBase =
    'https://github.com/MarvNC/yomichan-dictionaries/raw/master/dl';
const String _kuuuubeBase =
    'https://github.com/Kuuuube/yomitan-dictionaries/raw/main/dictionaries';

class DictionaryDownloader {
  DictionaryDownloader._();

  static const List<RecommendedDictionary> catalog = [
    // ── JA-EN ──
    RecommendedDictionary(
      name: 'JMdict (English)',
      url: '$_jmdictBase/JMdict_english.zip',
      description: 'Japanese-English dictionary',
      matchPrefix: 'JMdict (English)',
      category: DictionaryCategory.jaEn,
      sizeEstimate: '~22 MB',
      langCode: 'en',
    ),
    RecommendedDictionary(
      name: 'JMdict English + Examples',
      url: '$_jmdictBase/JMdict_english_with_examples.zip',
      description: 'JMdict with Tatoeba example sentences',
      matchPrefix: 'JMdict (English with Examples)',
      category: DictionaryCategory.jaEn,
      sizeEstimate: '~35 MB',
      langCode: 'en',
    ),
    RecommendedDictionary(
      name: 'Jitendex',
      url:
          'https://github.com/stephenmk/stephenmk.github.io/releases/latest/download/jitendex-yomitan.zip',
      description: 'Free JA-EN dictionary, rich formatting',
      matchPrefix: 'Jitendex',
      category: DictionaryCategory.jaEn,
      sizeEstimate: '~37 MB',
      langCode: 'en',
    ),

    // ── JA-JA (monolingual) ──
    RecommendedDictionary(
      name: 'Pixiv百科事典',
      url: '$_marvBase/%5BMonolingual%5D%20Pixiv.zip',
      description: 'ピクシブ百科事典 (pop culture)',
      matchPrefix: 'Pixiv',
      category: DictionaryCategory.jaJa,
      sizeEstimate: '~30 MB',
      langCode: 'ja',
    ),
    RecommendedDictionary(
      name: 'Nico-Pixiv百科事典',
      url: '$_marvBase/%5BOther%5D%20Nico-Pixiv.zip',
      description: 'ニコニコ大百科 + ピクシブ百科事典',
      matchPrefix: 'Nico-Pixiv',
      category: DictionaryCategory.jaJa,
      sizeEstimate: '~55 MB',
      langCode: 'ja',
    ),
    RecommendedDictionary(
      name: '複合語起源',
      url:
          '$_marvBase/%5BOther%5D%20%E8%A4%87%E5%90%88%E8%AA%9E%E8%B5%B7%E6%BA%90.zip',
      description: 'Compound word origins (語源辞典)',
      matchPrefix: '複合語起源',
      category: DictionaryCategory.jaJa,
      sizeEstimate: '~3 MB',
      langCode: 'ja',
    ),
    RecommendedDictionary(
      name: 'surasura',
      url: '$_marvBase/%5BMonolingual%5D%20surasura.zip',
      description: 'すらすら読解 (learner-friendly)',
      matchPrefix: 'surasura',
      category: DictionaryCategory.jaJa,
      sizeEstimate: '~2 MB',
      langCode: 'ja',
    ),

    // ── JA-Other languages ──
    RecommendedDictionary(
      name: 'JMdict (Dutch)',
      url: '$_jmdictBase/JMdict_dutch.zip',
      description: 'Japans-Nederlands woordenboek',
      matchPrefix: 'JMdict (Dutch)',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~15 MB',
      langCode: 'nl',
    ),
    RecommendedDictionary(
      name: 'JMdict (French)',
      url: '$_jmdictBase/JMdict_french.zip',
      description: 'Dictionnaire japonais-français',
      matchPrefix: 'JMdict (French)',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~15 MB',
      langCode: 'fr',
    ),
    RecommendedDictionary(
      name: 'JMdict (German)',
      url: '$_jmdictBase/JMdict_german.zip',
      description: 'Japanisch-Deutsches Wörterbuch',
      matchPrefix: 'JMdict (German)',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~15 MB',
      langCode: 'de',
    ),
    RecommendedDictionary(
      name: 'JMdict (Hungarian)',
      url: '$_jmdictBase/JMdict_hungarian.zip',
      description: 'Japán-magyar szótár',
      matchPrefix: 'JMdict (Hungarian)',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~15 MB',
      langCode: 'hu',
    ),
    RecommendedDictionary(
      name: 'JMdict (Russian)',
      url: '$_jmdictBase/JMdict_russian.zip',
      description: 'Японско-русский словарь',
      matchPrefix: 'JMdict (Russian)',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~15 MB',
      langCode: 'ru',
    ),
    RecommendedDictionary(
      name: 'JMdict (Slovenian)',
      url: '$_jmdictBase/JMdict_slovenian.zip',
      description: 'Japonsko-slovenski slovar',
      matchPrefix: 'JMdict (Slovenian)',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~15 MB',
      langCode: 'sl',
    ),
    RecommendedDictionary(
      name: 'JMdict (Spanish)',
      url: '$_jmdictBase/JMdict_spanish.zip',
      description: 'Diccionario japonés-español',
      matchPrefix: 'JMdict (Spanish)',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~15 MB',
      langCode: 'es',
    ),
    RecommendedDictionary(
      name: 'JMdict (Swedish)',
      url: '$_jmdictBase/JMdict_swedish.zip',
      description: 'Japanskt-svenskt lexikon',
      matchPrefix: 'JMdict (Swedish)',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~15 MB',
      langCode: 'sv',
    ),

    // ── Kanji ──
    RecommendedDictionary(
      name: 'KANJIDIC (English)',
      url: '$_jmdictBase/KANJIDIC_english.zip',
      description: 'Kanji readings & meanings (EN)',
      matchPrefix: 'KANJIDIC (English)',
      category: DictionaryCategory.kanji,
      sizeEstimate: '~5 MB',
      langCode: 'en',
    ),
    RecommendedDictionary(
      name: 'KANJIDIC (French)',
      url: '$_jmdictBase/KANJIDIC_french.zip',
      description: 'Lectures & significations des kanji (FR)',
      matchPrefix: 'KANJIDIC (French)',
      category: DictionaryCategory.kanji,
      sizeEstimate: '~5 MB',
      langCode: 'fr',
    ),
    RecommendedDictionary(
      name: 'KANJIDIC (Portuguese)',
      url: '$_jmdictBase/KANJIDIC_portuguese.zip',
      description: 'Leituras & significados de kanji (PT)',
      matchPrefix: 'KANJIDIC (Portuguese)',
      category: DictionaryCategory.kanji,
      sizeEstimate: '~5 MB',
      langCode: 'pt',
    ),
    RecommendedDictionary(
      name: 'KANJIDIC (Spanish)',
      url: '$_jmdictBase/KANJIDIC_spanish.zip',
      description: 'Lecturas & significados de kanji (ES)',
      matchPrefix: 'KANJIDIC (Spanish)',
      category: DictionaryCategory.kanji,
      sizeEstimate: '~5 MB',
      langCode: 'es',
    ),
    RecommendedDictionary(
      name: 'TheKanjiMap',
      url: '$_marvBase/%5BKanji%5D%20TheKanjiMap.zip',
      description: 'Kanji decomposition & components',
      matchPrefix: 'TheKanjiMap',
      category: DictionaryCategory.kanji,
      sizeEstimate: '~1 MB',
    ),
    RecommendedDictionary(
      name: 'Wiktionary Kanji',
      url: '$_marvBase/%5BKanji%5D%20Wiktionary.zip',
      description: 'Kanji from Wiktionary',
      matchPrefix: 'Wiktionary',
      category: DictionaryCategory.kanji,
      sizeEstimate: '~4 MB',
    ),

    // ── Frequency ──
    RecommendedDictionary(
      name: 'JPDB Frequency',
      url:
          'https://github.com/MarvNC/jpdb-freq-list/releases/latest/download/JPDB.Frequency.List.zip',
      description: 'Word frequency from jpdb.io',
      matchPrefix: 'JPDB Frequency',
      category: DictionaryCategory.frequency,
      sizeEstimate: '~1 MB',
    ),
    RecommendedDictionary(
      name: 'BCCWJ Frequency',
      url: '$_kuuuubeBase/BCCWJ_SUW_LUW_combined.zip',
      description: 'Balanced Corpus of Contemporary Written Japanese',
      matchPrefix: 'BCCWJ',
      category: DictionaryCategory.frequency,
      sizeEstimate: '~1 MB',
    ),
    RecommendedDictionary(
      name: 'Aozora Bunko Frequency',
      url: '$_marvBase/%5BFreq%5D%20Aozora%20Bunko.zip',
      description: 'Frequency from 青空文庫 (classic literature)',
      matchPrefix: 'Aozora',
      category: DictionaryCategory.frequency,
      sizeEstimate: '~1 MB',
    ),
    RecommendedDictionary(
      name: 'JPDB Kanji Frequency',
      url: '$_marvBase/%5BKanji%20Frequency%5D%20JPDB%20Kanji.zip',
      description: 'Kanji frequency from jpdb.io',
      matchPrefix: 'JPDB Kanji',
      category: DictionaryCategory.frequency,
      sizeEstimate: '~1 MB',
    ),
    RecommendedDictionary(
      name: 'Innocent Corpus Kanji Freq',
      url: '$_marvBase/%5BKanji%20Frequency%5D%20Innocent%20Corpus%20Kanji.zip',
      description: 'Kanji frequency from novels',
      matchPrefix: 'Innocent',
      category: DictionaryCategory.frequency,
      sizeEstimate: '~1 MB',
    ),

    // ── Names ──
    RecommendedDictionary(
      name: 'JMnedict',
      url: '$_jmdictBase/JMnedict.zip',
      description: 'Japanese proper names (人名・地名)',
      matchPrefix: 'JMnedict',
      category: DictionaryCategory.names,
      sizeEstimate: '~12 MB',
    ),

    // ── Supplementary ──
    RecommendedDictionary(
      name: 'JMdict Forms',
      url: '$_jmdictBase/JMdict_forms.zip',
      description: 'Word forms for conjugation lookup',
      matchPrefix: 'JMdict Forms',
      category: DictionaryCategory.supplementary,
      sizeEstimate: '~5 MB',
    ),
    RecommendedDictionary(
      name: '字体 (Jitai)',
      url: '$_marvBase/%5BKanji%5D%20jitai.zip',
      description: 'Kanji font variant info',
      matchPrefix: 'jitai',
      category: DictionaryCategory.supplementary,
      sizeEstimate: '~1 MB',
    ),
    RecommendedDictionary(
      name: 'mozc Kanji Variants',
      url: '$_marvBase/%5BKanji%5D%20mozc%20Kanji%20Variants.zip',
      description: 'Kanji variant forms (異体字)',
      matchPrefix: 'mozc',
      category: DictionaryCategory.supplementary,
      sizeEstimate: '~1 MB',
    ),
  ];

  static Map<DictionaryCategory, List<RecommendedDictionary>> get byCategory {
    final map = <DictionaryCategory, List<RecommendedDictionary>>{};
    for (final cat in DictionaryCategory.values) {
      final items = catalog.where((d) => d.category == cat).toList();
      if (items.isNotEmpty) map[cat] = items;
    }
    return map;
  }

  /// Returns indices into [catalog] that should be pre-checked for a locale.
  /// Logic: match the user's language to a JMdict variant + JPDB frequency.
  /// Chinese/Korean users get JMdict English as fallback (most complete).
  static Set<int> defaultSelectionFor(Locale locale) {
    final lang = locale.languageCode;
    final selected = <int>{};

    // Always include JPDB Frequency.
    for (int i = 0; i < catalog.length; i++) {
      if (catalog[i].matchPrefix == 'JPDB Frequency') {
        selected.add(i);
        break;
      }
    }

    // For Japanese locale → recommend JA-JA dicts.
    if (lang == 'ja') {
      for (int i = 0; i < catalog.length; i++) {
        if (catalog[i].category == DictionaryCategory.jaJa) {
          selected.add(i);
        }
      }
      return selected;
    }

    // Try to find a JMdict matching the user's language.
    bool foundMatch = false;
    for (int i = 0; i < catalog.length; i++) {
      final d = catalog[i];
      if (d.langCode == lang &&
          d.name.startsWith('JMdict') &&
          d.category != DictionaryCategory.jaEn) {
        selected.add(i);
        foundMatch = true;
        break;
      }
    }

    // Always include JMdict English for non-JA users.
    for (int i = 0; i < catalog.length; i++) {
      if (catalog[i].name == 'JMdict (English)') {
        selected.add(i);
        break;
      }
    }

    // For Chinese/Korean users without a dedicated JMdict,
    // also recommend lightweight JA-JA dicts (skip large ones like Nico-Pixiv).
    if (!foundMatch && (lang == 'zh' || lang == 'ko')) {
      for (int i = 0; i < catalog.length; i++) {
        final d = catalog[i];
        if (d.category == DictionaryCategory.jaJa &&
            d.name != 'Nico-Pixiv百科事典') {
          selected.add(i);
        }
      }
    }

    return selected;
  }

  static Future<File> download({
    required String url,
    required Directory tempDir,
    required ValueNotifier<double> progressNotifier,
    CancelToken? cancelToken,
  }) async {
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    final String fileName = Uri.parse(url).pathSegments.last;
    final String destPath = path.join(tempDir.path, fileName);
    final Dio dio = Dio();

    try {
      await dio.download(
        url,
        destPath,
        cancelToken: cancelToken,
        options: Options(
          followRedirects: true,
          maxRedirects: 5,
        ),
        onReceiveProgress: (int received, int total) {
          if (total > 0) {
            progressNotifier.value = received / total;
          }
        },
      );
      return File(destPath);
    } finally {
      dio.close();
    }
  }
}
