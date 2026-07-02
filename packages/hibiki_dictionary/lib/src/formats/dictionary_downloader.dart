import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

enum DictionaryCategory {
  jaEn,
  jaJa,
  jaOther,
  grammar,
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

  /// TODO-1075：本条目对应的**远端 index.json 可访问 URL**（供在线更新检查拉
  /// revision 比对；见 [DictionaryUpdateService.fetchRemoteIndex]）。
  ///
  /// 只有确实提供「与 zip 分离的、可 HTTP GET 到 index.json」端点的来源才非 null：
  /// - yomidevs `jmdict-yomitan` releases：sibling `<X>.json`（把 `.zip` 换 `.json`，
  ///   实测 JMdict/KANJIDIC/JMnedict/Forms 等全部 200）。
  /// - wty（HuggingFace daxida/wty-release）：`.../latest/index/wty-ja-<lang>-index.json
  ///   ?download=true`（与 zip 路径不同构，单独派生）。
  ///
  /// 其余来源（MarvNC / Kuuuube git-raw、grammar/frequency 打包等）**没有**分离的
  /// index 端点，返回 null → catalog 导入不置 `isUpdatable`，可更新性完全交回词典包
  /// 自身 index.json 的声明（不误标不可更新来源为可更新，避免对无源词典发更新请求）。
  ///
  /// 这是把「可更新性」的权威信号锚定在 catalog（我们控制的来源真值），而不是脆弱地
  /// 依赖第三方包内是否碰巧声明 `isUpdatable`——修 TODO-1075 的初装 gate 空档。
  String? get indexUrl {
    const String yomidevsPrefix =
        'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/';
    if (url.startsWith(yomidevsPrefix) && url.endsWith('.zip')) {
      return '${url.substring(0, url.length - '.zip'.length)}.json';
    }
    // wty: .../latest/dict/ja/<lang>/wty-ja-<lang>.zip
    //   →  .../latest/index/wty-ja-<lang>-index.json?download=true
    final RegExp wtyRe = RegExp(
      r'^(https://huggingface\.co/datasets/daxida/wty-release/resolve/main/latest)/dict/ja/([a-z-]+)/(wty-ja-[a-z-]+)\.zip$',
    );
    final RegExpMatch? m = wtyRe.firstMatch(url);
    if (m != null) {
      final String base = m.group(1)!;
      final String stem = m.group(3)!;
      return '$base/index/$stem-index.json?download=true';
    }
    return null;
  }

  /// TODO-1075：本条目是否可作为「可在线更新」的来源导入（存在分离 index 端点）。
  bool get isCatalogUpdatable => indexUrl != null;
}

const String _jmdictBase =
    'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download';
const String _marvBase =
    'https://raw.githubusercontent.com/MarvNC/yomitan-dictionaries/master/dl';
const String _kuuuubeBase =
    'https://github.com/Kuuuube/yomitan-dictionaries/raw/main/dictionaries';
const String _wtyBase =
    'https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/dict';

class DictionaryDownloader {
  DictionaryDownloader._();

  /// All target languages with at least one available dictionary.
  /// Keys are ISO 639-1 codes, values are native display names.
  static const Map<String, String> availableLanguages = {
    'ja': '日本語',
    'en': 'English',
    'zh': '中文',
    'ko': '한국어',
    'de': 'Deutsch',
    'es': 'Español',
    'fr': 'Français',
    'ru': 'Русский',
    'nl': 'Nederlands',
    'hu': 'Magyar',
    'sl': 'Slovenščina',
    'sv': 'Svenska',
    'it': 'Italiano',
    'pt': 'Português',
    'vi': 'Tiếng Việt',
    'th': 'ไทย',
    'id': 'Bahasa Indonesia',
    'pl': 'Polski',
    'mn': 'Монгол',
    'tr': 'Türkçe',
    'cs': 'Čeština',
    'el': 'Ελληνικά',
    'ms': 'Bahasa Melayu',
  };

  /// Language codes where a main wty-ja-{lang}.zip exists.
  static const Set<String> _wtyMainLanguages = {
    'en',
    'zh',
    'ko',
    'it',
    'pt',
    'vi',
    'th',
    'id',
    'pl',
    'de',
    'fr',
    'es',
    'ru',
    'nl',
    'tr',
    'cs',
    'el',
    'ms',
  };

  /// Creates a Wiktionary bilingual entry for [langCode].
  /// Returns null if already in [catalog] or unsupported.
  static RecommendedDictionary? wtyDictForLang(String langCode) {
    if (!_wtyMainLanguages.contains(langCode) || langCode == 'ja') return null;
    final String prefix = 'wty-ja-$langCode';
    if (catalog.any((d) => d.matchPrefix == prefix)) return null;
    final String name = availableLanguages[langCode] ?? langCode.toUpperCase();
    return RecommendedDictionary(
      name: 'Wiktionary JA-${langCode.toUpperCase()} ($name)',
      url: '$_wtyBase/ja/$langCode/wty-ja-$langCode.zip',
      description: 'Wiktionary Japanese–$name',
      matchPrefix: prefix,
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: langCode,
    );
  }

  /// Returns [catalog] extended with a dynamic wty entry for [langCode].
  static List<RecommendedDictionary> catalogForLang(String langCode) {
    final List<RecommendedDictionary> result = catalog.toList();
    final RecommendedDictionary? wty = wtyDictForLang(langCode);
    if (wty != null) result.add(wty);
    return result;
  }

  /// Groups [items] by category.
  static Map<DictionaryCategory, List<RecommendedDictionary>> byCategoryFrom(
    List<RecommendedDictionary> items,
  ) {
    final Map<DictionaryCategory, List<RecommendedDictionary>> map = {};
    for (final DictionaryCategory cat in DictionaryCategory.values) {
      final List<RecommendedDictionary> catItems =
          items.where((d) => d.category == cat).toList();
      if (catItems.isNotEmpty) map[cat] = catItems;
    }
    return map;
  }

  static const List<RecommendedDictionary> catalog = [
    // ── JA-EN ──
    RecommendedDictionary(
      name: 'JMdict (English)',
      url: '$_jmdictBase/JMdict_english.zip',
      description: 'Japanese-English dictionary',
      matchPrefix: 'JMdict',
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

    // ── JA-EN (additional) ──
    RecommendedDictionary(
      name: 'Wiktionary JA-EN',
      url: '$_wtyBase/ja/en/wty-ja-en.zip',
      description: 'Wiktionary-based JA-EN dictionary',
      matchPrefix: 'wty-ja-en',
      category: DictionaryCategory.jaEn,
      sizeEstimate: '~15 MB',
      langCode: 'en',
    ),

    // ── JA-JA ──
    RecommendedDictionary(
      name: 'Wiktionary JA-JA',
      url: '$_wtyBase/ja/ja/wty-ja-ja.zip',
      description: '日本語版ウィクショナリー — 無料の国語辞典型リソース',
      matchPrefix: 'wty-ja-ja',
      category: DictionaryCategory.jaJa,
      sizeEstimate: '~13 MB',
      langCode: 'ja',
    ),
    RecommendedDictionary(
      name: 'Pixiv百科事典',
      url: '$_marvBase/%5BMonolingual%5D%20Pixiv.zip',
      description: '百科事典 — ポップカルチャー用語',
      matchPrefix: 'Pixiv',
      category: DictionaryCategory.jaJa,
      sizeEstimate: '~30 MB',
      langCode: 'ja',
    ),
    RecommendedDictionary(
      name: 'Nico-Pixiv百科事典',
      url: '$_marvBase/%5BOther%5D%20Nico-Pixiv.zip',
      description: '百科事典 — ニコニコ+ピクシブ',
      matchPrefix: 'Nico-Pixiv',
      category: DictionaryCategory.jaJa,
      sizeEstimate: '~55 MB',
      langCode: 'ja',
    ),
    RecommendedDictionary(
      name: '複合語起源',
      url:
          '$_marvBase/%5BOther%5D%20%E8%A4%87%E5%90%88%E8%AA%9E%E8%B5%B7%E6%BA%90.zip',
      description: '語源辞典 — 複合語の語源',
      matchPrefix: '複合語起源',
      category: DictionaryCategory.jaJa,
      sizeEstimate: '~3 MB',
      langCode: 'ja',
    ),
    RecommendedDictionary(
      name: 'surasura',
      url: '$_marvBase/%5BMonolingual%5D%20surasura.zip',
      description: '読解補助 — すらすら読解',
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
    RecommendedDictionary(
      name: 'Wiktionary JA-ZH (中文)',
      url: '$_wtyBase/ja/zh/wty-ja-zh.zip',
      description: '维基词典 日中词典',
      matchPrefix: 'wty-ja-zh',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: 'zh',
    ),
    RecommendedDictionary(
      name: 'Wiktionary JA-KO (한국어)',
      url: '$_wtyBase/ja/ko/wty-ja-ko.zip',
      description: '위키낱말사전 일한사전',
      matchPrefix: 'wty-ja-ko',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: 'ko',
    ),
    RecommendedDictionary(
      name: 'Wiktionary JA-IT (Italiano)',
      url: '$_wtyBase/ja/it/wty-ja-it.zip',
      description: 'Dizionario giapponese-italiano da Wiktionary',
      matchPrefix: 'wty-ja-it',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: 'it',
    ),
    RecommendedDictionary(
      name: 'Wiktionary JA-PT (Português)',
      url: '$_wtyBase/ja/pt/wty-ja-pt.zip',
      description: 'Dicionário japonês-português do Wiktionary',
      matchPrefix: 'wty-ja-pt',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: 'pt',
    ),
    RecommendedDictionary(
      name: 'Wiktionary JA-VI (Tiếng Việt)',
      url: '$_wtyBase/ja/vi/wty-ja-vi.zip',
      description: 'Từ điển Nhật-Việt từ Wiktionary',
      matchPrefix: 'wty-ja-vi',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: 'vi',
    ),
    RecommendedDictionary(
      name: 'Wiktionary JA-TH (ไทย)',
      url: '$_wtyBase/ja/th/wty-ja-th.zip',
      description: 'พจนานุกรมญี่ปุ่น-ไทย จาก Wiktionary',
      matchPrefix: 'wty-ja-th',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: 'th',
    ),
    RecommendedDictionary(
      name: 'Wiktionary JA-ID (Indonesia)',
      url: '$_wtyBase/ja/id/wty-ja-id.zip',
      description: 'Kamus Jepang-Indonesia dari Wiktionary',
      matchPrefix: 'wty-ja-id',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: 'id',
    ),
    RecommendedDictionary(
      name: 'Wiktionary JA-PL (Polski)',
      url: '$_wtyBase/ja/pl/wty-ja-pl.zip',
      description: 'Słownik japońsko-polski z Wiktionary',
      matchPrefix: 'wty-ja-pl',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~10 MB',
      langCode: 'pl',
    ),
    RecommendedDictionary(
      name: '日・モ辞典 (Mongolian)',
      url:
          '$_marvBase/%5BJP-Mongolian%5D%20Japanese-Mongolian%20%E6%97%A5%E3%83%BB%E3%83%A2%E8%BE%9E%E5%85%B8%20(No%20Sentences).zip',
      description: 'Японо-монгольский словарь',
      matchPrefix: '日・モ辞典',
      category: DictionaryCategory.jaOther,
      sizeEstimate: '~5 MB',
      langCode: 'mn',
    ),

    // ── Grammar ──
    RecommendedDictionary(
      name: '日本語文型辞典',
      url:
          'https://github.com/HuangAntimony/Nihongo-Bunkei-Jiten/releases/latest/download/Nihongo-Bunkei-Jiten.zip',
      description: 'Japanese grammar patterns — 文法パターン辞典',
      matchPrefix: 'Nihongo-Bunkei-Jiten',
      category: DictionaryCategory.grammar,
      sizeEstimate: '~5 MB',
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
      matchPrefix: 'Wiktionary Kanji',
      category: DictionaryCategory.kanji,
      sizeEstimate: '~4 MB',
    ),

    // ── Frequency ──
    RecommendedDictionary(
      name: 'JPDB Frequency',
      url:
          'https://github.com/MarvNC/jpdb-freq-list/releases/download/2022-05-09/Freq.JPDB_2022-05-10T03_27_02.930Z.zip',
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
    RecommendedDictionary(
      name: 'Wikipedia Kanji Frequency',
      url: '$_marvBase/%5BKanji%20Frequency%5D%20Wikipedia.zip',
      description: 'Kanji frequency from Wikipedia',
      matchPrefix: 'Wikipedia',
      category: DictionaryCategory.frequency,
      sizeEstimate: '~1 MB',
    ),
    RecommendedDictionary(
      name: 'H Frequency',
      url: '$_kuuuubeBase/H_Freq.zip',
      description: 'Word frequency from voice work scripts',
      matchPrefix: 'H Freq',
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

  static Map<DictionaryCategory, List<RecommendedDictionary>> get byCategory =>
      byCategoryFrom(catalog);

  /// Returns indices into [catalog] that should be pre-checked for a locale.
  static Set<int> defaultSelectionFor(Locale locale) =>
      defaultSelectionForLang(locale.languageCode, catalog);

  /// Returns pre-checked indices for [lang] within [workingCatalog].
  static Set<int> defaultSelectionForLang(
    String lang,
    List<RecommendedDictionary> workingCatalog,
  ) {
    final Set<int> selected = {};

    for (int i = 0; i < workingCatalog.length; i++) {
      if (workingCatalog[i].matchPrefix == 'JPDB Frequency') {
        selected.add(i);
        break;
      }
    }

    if (lang == 'ja') {
      for (int i = 0; i < workingCatalog.length; i++) {
        if (workingCatalog[i].matchPrefix == 'wty-ja-ja') {
          selected.add(i);
        }
      }
      return selected;
    }

    bool foundMatch = false;
    for (int i = 0; i < workingCatalog.length; i++) {
      final RecommendedDictionary d = workingCatalog[i];
      if (d.langCode == lang &&
          d.name.startsWith('JMdict') &&
          d.category != DictionaryCategory.jaEn) {
        selected.add(i);
        foundMatch = true;
        break;
      }
    }

    for (int i = 0; i < workingCatalog.length; i++) {
      if (workingCatalog[i].name == 'JMdict (English)') {
        selected.add(i);
        break;
      }
    }

    if (!foundMatch && lang != 'en') {
      final String wtyPrefix = 'wty-ja-$lang';
      for (int i = 0; i < workingCatalog.length; i++) {
        if (workingCatalog[i].matchPrefix == wtyPrefix) {
          selected.add(i);
          foundMatch = true;
          break;
        }
      }
    }

    if (!foundMatch) {
      for (int i = 0; i < workingCatalog.length; i++) {
        final RecommendedDictionary d = workingCatalog[i];
        if (d.langCode == lang &&
            d.category == DictionaryCategory.jaOther &&
            !d.name.startsWith('JMdict')) {
          selected.add(i);
          break;
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
