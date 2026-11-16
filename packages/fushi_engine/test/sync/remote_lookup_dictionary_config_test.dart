import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:test/test.dart';

/// 远程查词带**请求方配置的词典选择**（wire 字段 `dictionaries`，
/// `{excluded: [...], order: [...]}`）：认识它的 host 按它查、回执
/// `dictionaryConfigApplied: true`；不认识（旧实现 / 测试替身）或请求没带时走原分派、
/// 不带回执。另含 `/api/library/dictionaries` 清单条目的目录字段。

/// 只认识语言 / ruby、不认识词典选择的 service（旧 host / 测试替身）。
class _LegacyLookup
    implements
        FushiRemoteLookupService,
        FushiRemotePopupLookupService,
        FushiRemoteLanguageLookupService,
        FushiRemoteRubyLookupService {
  final List<String> calls = <String>[];

  DictionarySearchResult _full(String term) =>
      DictionarySearchResult(searchTerm: term, bestLength: 1);
  static const RemoteDictionaryPopupLookup _popup = RemoteDictionaryPopupLookup(
    popupJson: '[]',
    bestLength: 1,
  );

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    calls.add('full');
    return _full(term);
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    calls.add('popup');
    return _popup;
  }

  @override
  Future<DictionarySearchResult?> searchDictionaryInLanguage({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required String? language,
    bool? chineseScriptVariants,
  }) async {
    calls.add('full-language');
    return _full(term);
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupInLanguage({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required String? language,
    bool? chineseScriptVariants,
    RemoteDictionaryPopupTiming? timing,
  }) async {
    calls.add('popup-language');
    return _popup;
  }

  @override
  Future<DictionarySearchResult?> searchDictionaryWithRuby({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required List<FushiRubySpan> rubySpans,
    String? language,
    bool? chineseScriptVariants,
  }) async {
    calls.add('full-ruby');
    return _full(term);
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupWithRuby({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required List<FushiRubySpan> rubySpans,
    String? language,
    bool? chineseScriptVariants,
    RemoteDictionaryPopupTiming? timing,
  }) async {
    calls.add('popup-ruby');
    return _popup;
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

/// 认识词典选择的 service：记下收到的选择与其余参数。
class _FilteredLookup extends _LegacyLookup
    implements FushiRemoteFilteredLookupService {
  final List<RemoteLookupDictionaryConfig> configs =
      <RemoteLookupDictionaryConfig>[];
  final List<String?> languages = <String?>[];
  final List<bool?> scriptVariants = <bool?>[];
  final List<List<FushiRubySpan>> spans = <List<FushiRubySpan>>[];
  RemoteDictionaryPopupTiming? lastTiming;

  @override
  Future<DictionarySearchResult?> searchDictionaryFiltered({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required RemoteLookupDictionaryConfig dictionaryConfig,
    String? language,
    bool? chineseScriptVariants,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
  }) async {
    calls.add('full-filtered');
    configs.add(dictionaryConfig);
    languages.add(language);
    scriptVariants.add(chineseScriptVariants);
    spans.add(rubySpans);
    return _full(term);
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupFiltered({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required RemoteLookupDictionaryConfig dictionaryConfig,
    String? language,
    bool? chineseScriptVariants,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
    RemoteDictionaryPopupTiming? timing,
  }) async {
    calls.add('popup-filtered');
    configs.add(dictionaryConfig);
    languages.add(language);
    scriptVariants.add(chineseScriptVariants);
    spans.add(rubySpans);
    lastTiming = timing;
    return _LegacyLookup._popup;
  }
}

const Map<String, Object?> _selection = <String, Object?>{
  'excluded': <String>['Hidden'],
  'order': <String>['B', 'A'],
};

void main() {
  group('handler 分派', () {
    test(
      '带选择 + service 认识 ⇒ 走 filtered（完整），选择与语言 / ruby 一并交给它，回执 true',
      () async {
        final _FilteredLookup lookup = _FilteredLookup();
        final Map<String, dynamic> resp =
            await buildRemoteDictionaryLookupResponse(<String, dynamic>{
              'term': '忙しい',
              kRemoteLookupDictionariesField: _selection,
              kRemoteLookupLanguageField: 'ja',
              kRemoteLookupChineseScriptVariantsField: true,
              kRemoteLookupRubyField: <Object>[
                <String, Object>{'s': 0, 'e': 1, 'r': 'せわ'},
              ],
            }, lookup: lookup);
        expect(lookup.calls, <String>['full-filtered']);
        expect(lookup.configs.single.excluded, <String>{'Hidden'});
        expect(lookup.configs.single.order, <String>['B', 'A']);
        expect(lookup.languages.single, 'ja');
        expect(lookup.scriptVariants.single, isTrue);
        expect(lookup.spans.single, <FushiRubySpan>[
          const FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
        ]);
        expect(resp[kRemoteLookupDictionaryConfigAppliedField], isTrue);
        expect(resp['result'], isNotNull);
      },
    );

    test('带选择 + popupOnly ⇒ 走 filtered popup 快路径，timing 透传，回执 true', () async {
      final _FilteredLookup lookup = _FilteredLookup();
      final RemoteDictionaryPopupTiming timing = RemoteDictionaryPopupTiming();
      final Map<String, dynamic> resp =
          await buildRemoteDictionaryLookupResponse(
            <String, dynamic>{
              'term': '忙しい',
              'popupOnly': true,
              kRemoteLookupDictionariesField: _selection,
            },
            lookup: lookup,
            popupTiming: timing,
          );
      expect(lookup.calls, <String>['popup-filtered']);
      expect(identical(lookup.lastTiming, timing), isTrue);
      expect(resp[kRemoteLookupDictionaryConfigAppliedField], isTrue);
      expect(resp['popupJson'], '[]');
    });

    test('不带选择 ⇒ 原分派（语言版），不带回执', () async {
      final _FilteredLookup lookup = _FilteredLookup();
      final Map<String, dynamic> resp =
          await buildRemoteDictionaryLookupResponse(<String, dynamic>{
            'term': '忙しい',
            kRemoteLookupLanguageField: 'ja',
          }, lookup: lookup);
      expect(lookup.calls, <String>['full-language']);
      expect(lookup.configs, isEmpty);
      expect(
        resp.containsKey(kRemoteLookupDictionaryConfigAppliedField),
        isFalse,
      );
    });

    test('畸形选择（非对象 / 两个名单都不是数组）当没给：原分派、不带回执', () async {
      for (final Object? malformed in <Object?>[
        'A,B',
        <String>['A'],
        <String, Object?>{'excluded': 'A', 'order': 3},
        <String, Object?>{},
      ]) {
        final _FilteredLookup lookup = _FilteredLookup();
        final Map<String, dynamic> resp =
            await buildRemoteDictionaryLookupResponse(<String, dynamic>{
              'term': '忙しい',
              kRemoteLookupDictionariesField: malformed,
            }, lookup: lookup);
        expect(lookup.calls, <String>['full'], reason: '$malformed');
        expect(
          resp.containsKey(kRemoteLookupDictionaryConfigAppliedField),
          isFalse,
          reason: '$malformed',
        );
      }
    });

    test('名单里的非字符串 / 空串项丢弃，其余照用', () async {
      final _FilteredLookup lookup = _FilteredLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '忙しい',
        kRemoteLookupDictionariesField: <String, Object?>{
          'excluded': <Object?>['X', 3, '', null],
        },
      }, lookup: lookup);
      expect(lookup.calls, <String>['full-filtered']);
      expect(lookup.configs.single.excluded, <String>{'X'});
      expect(lookup.configs.single.order, isEmpty);
    });

    test('带选择但 service 不认识（旧 host）⇒ 原分派，不带回执', () async {
      final _LegacyLookup lookup = _LegacyLookup();
      final Map<String, dynamic> full =
          await buildRemoteDictionaryLookupResponse(<String, dynamic>{
            'term': '忙しい',
            kRemoteLookupDictionariesField: _selection,
          }, lookup: lookup);
      final Map<String, dynamic> popup =
          await buildRemoteDictionaryLookupResponse(<String, dynamic>{
            'term': '忙しい',
            'popupOnly': true,
            kRemoteLookupDictionariesField: _selection,
          }, lookup: lookup);
      expect(lookup.calls, <String>['full', 'popup']);
      expect(
        full.containsKey(kRemoteLookupDictionaryConfigAppliedField),
        isFalse,
      );
      expect(
        popup.containsKey(kRemoteLookupDictionaryConfigAppliedField),
        isFalse,
      );
    });

    test('空 term 不查词、不带回执', () async {
      final _FilteredLookup lookup = _FilteredLookup();
      final Map<String, dynamic> resp =
          await buildRemoteDictionaryLookupResponse(<String, dynamic>{
            'term': ' ',
            kRemoteLookupDictionariesField: _selection,
          }, lookup: lookup);
      expect(lookup.calls, isEmpty);
      expect(
        resp.containsKey(kRemoteLookupDictionaryConfigAppliedField),
        isFalse,
      );
    });
  });

  group('分派函数', () {
    const RemoteLookupDictionaryConfig config = RemoteLookupDictionaryConfig(
      excluded: <String>{'Hidden'},
      order: <String>['A'],
    );

    test('usesRemoteFilteredLookup 只在「有选择 + 认识」时为 true', () {
      expect(usesRemoteFilteredLookup(_FilteredLookup(), config), isTrue);
      expect(usesRemoteFilteredLookup(_FilteredLookup(), null), isFalse);
      expect(usesRemoteFilteredLookup(_LegacyLookup(), config), isFalse);
    });

    test('filtered 优先于 ruby 分派；空名单也是一份权威选择', () async {
      final _FilteredLookup lookup = _FilteredLookup();
      await searchRemoteDictionaryForRequest(
        lookup,
        term: 't',
        wildcards: false,
        maximumTerms: 5,
        language: null,
        rubySpans: const <FushiRubySpan>[
          FushiRubySpan(start: 0, end: 1, reading: 'て'),
        ],
        dictionaryConfig: const RemoteLookupDictionaryConfig(
          excluded: <String>{},
          order: <String>[],
        ),
      );
      expect(lookup.calls, <String>['full-filtered']);
      expect(lookup.configs.single.isEmpty, isTrue);
    });

    test('hasPopupFastPath：只认识 filtered（无旧 popup 接口）的 service 带选择时有快路径', () {
      final _FilteredOnlyLookup lookup = _FilteredOnlyLookup();
      expect(hasPopupFastPath(lookup), isFalse);
      expect(hasPopupFastPath(lookup, dictionaryConfig: config), isTrue);
    });

    test('RemoteLookupDictionaryConfig.toJson 经 wire 往返不变', () {
      final RemoteLookupDictionaryConfig? back = remoteLookupDictionaryConfigOf(
        <String, dynamic>{kRemoteLookupDictionariesField: config.toJson()},
      );
      expect(back?.excluded, config.excluded);
      expect(back?.order, config.order);
    });
  });

  group('RemoteDictionaryInfo', () {
    test('全字段往返；null 字段不写进 JSON', () {
      const RemoteDictionaryInfo full = RemoteDictionaryInfo(
        name: 'JMdict',
        type: 'term',
        formatKey: 'yomichan',
        revision: 'jmdict4',
        displayName: '辞書',
        sourceLanguage: 'ja',
        defaultEnabled: false,
      );
      final RemoteDictionaryInfo back = RemoteDictionaryInfo.fromJson(
        full.toJson(),
      );
      expect(back.defaultEnabled, isFalse);
      expect(back.name, 'JMdict');
      expect(back.type, 'term');
      expect(back.formatKey, 'yomichan');
      expect(back.revision, 'jmdict4');
      expect(back.displayName, '辞書');
      expect(back.sourceLanguage, 'ja');

      const RemoteDictionaryInfo bare = RemoteDictionaryInfo(
        name: 'Old',
        type: 'term',
      );
      expect(bare.toJson(), <String, Object?>{'name': 'Old', 'type': 'term'});
    });

    test('fromJson 宽容：老 host 缺键、非字符串、空白串一律 null', () {
      final RemoteDictionaryInfo old = RemoteDictionaryInfo.fromJson(
        const <String, Object?>{'name': 'Old', 'type': 'term'},
      );
      expect(old.formatKey, isNull);
      expect(old.revision, isNull);
      expect(old.displayName, isNull);
      expect(old.sourceLanguage, isNull);
      expect(old.defaultEnabled, isNull);
      final RemoteDictionaryInfo weird = RemoteDictionaryInfo.fromJson(
        const <String, Object?>{
          'name': 'W',
          'type': 'term',
          'formatKey': 3,
          'revision': '  ',
          'displayName': null,
          'sourceLanguage': <String>['ja'],
          'defaultEnabled': 'false',
        },
      );
      expect(weird.defaultEnabled, isNull);
      expect(weird.formatKey, isNull);
      expect(weird.revision, isNull);
      expect(weird.displayName, isNull);
      expect(weird.sourceLanguage, isNull);
    });

    DictionaryMetaRow row({
      String metadataJson = '{}',
      String? languageOverride,
      String? displayName,
      String hiddenLanguagesJson = '[]',
    }) => DictionaryMetaRow(
      name: 'JMdict',
      formatKey: 'yomichan',
      order: 0,
      type: 'term',
      metadataJson: metadataJson,
      hiddenLanguagesJson: hiddenLanguagesJson,
      collapsedLanguagesJson: '[]',
      expandedLanguagesJson: '[]',
      languageOverride: languageOverride,
      displayName: displayName,
    );

    test('fromMetadataRow：revision / sourceLanguage 取 metadataJson，显示名取列', () {
      final RemoteDictionaryInfo info = RemoteDictionaryInfo.fromMetadataRow(
        row(
          metadataJson: '{"revision":"jmdict4","sourceLanguage":"ja"}',
          displayName: '辞書',
        ),
      );
      expect(info.name, 'JMdict');
      expect(info.type, 'term');
      expect(info.formatKey, 'yomichan');
      expect(info.revision, 'jmdict4');
      expect(info.sourceLanguage, 'ja');
      expect(info.displayName, '辞書');
    });

    test(
      'fromMetadataRow：languageOverride 优先于 index.json 的 sourceLanguage',
      () {
        expect(
          RemoteDictionaryInfo.fromMetadataRow(
            row(
              metadataJson: '{"sourceLanguage":"ja"}',
              languageOverride: 'zh-Hant',
            ),
          ).sourceLanguage,
          'zh-Hant',
        );
        // 空白 override 当没指定（与 Dictionary.effectiveSourceLanguage 同判据）。
        expect(
          RemoteDictionaryInfo.fromMetadataRow(
            row(metadataJson: '{"sourceLanguage":"ja"}', languageOverride: ' '),
          ).sourceLanguage,
          'ja',
        );
      },
    );

    test('fromMetadataRow：metadataJson 畸形 / 缺键 ⇒ 目录字段 null，name / type 照发', () {
      final RemoteDictionaryInfo info = RemoteDictionaryInfo.fromMetadataRow(
        row(metadataJson: '{not json', displayName: ''),
      );
      expect(info.name, 'JMdict');
      expect(info.revision, isNull);
      expect(info.sourceLanguage, isNull);
      expect(info.displayName, isNull);
      expect(info.toJson().containsKey('revision'), isFalse);
    });

    test('fromMetadataRow：defaultEnabled = hiddenLanguagesJson 不含 ja', () {
      bool? enabledOf(String hidden) => RemoteDictionaryInfo.fromMetadataRow(
        row(hiddenLanguagesJson: hidden),
      ).defaultEnabled;
      expect(enabledOf('[]'), isTrue);
      expect(enabledOf('["ja"]'), isFalse);
      expect(enabledOf('["en","ja"]'), isFalse);
      expect(enabledOf('["en"]'), isTrue);
      // 畸形 / 非数组当没关（与服务端装载时的默认过滤同一判据）。
      expect(enabledOf('{oops'), isTrue);
      expect(enabledOf('"ja"'), isTrue);
      expect(
        RemoteDictionaryInfo.isDictionaryHiddenByDefault(
          row(hiddenLanguagesJson: '["ja"]'),
        ),
        isTrue,
      );
    });
  });
}

/// 只认识 filtered、没有旧 popup 接口的 service。
class _FilteredOnlyLookup
    implements FushiRemoteLookupService, FushiRemoteFilteredLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => null;

  @override
  Future<DictionarySearchResult?> searchDictionaryFiltered({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required RemoteLookupDictionaryConfig dictionaryConfig,
    String? language,
    bool? chineseScriptVariants,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
  }) async => null;

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupFiltered({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required RemoteLookupDictionaryConfig dictionaryConfig,
    String? language,
    bool? chineseScriptVariants,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
    RemoteDictionaryPopupTiming? timing,
  }) async => null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}
