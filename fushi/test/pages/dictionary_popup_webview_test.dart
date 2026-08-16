import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/source_guard.dart';

void main() {
  group('dictionary popup asset bootstrap', () {
    test('iOS uses inline popup assets instead of a file URL main frame', () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('defaultTargetPlatform == TargetPlatform.iOS'),
        reason: 'iOS WKWebView can fail the popup.html file:// main-frame '
            'load in Simulator; it must share the inline bootstrap path.',
      );
      expect(source, contains('final bool shouldInlinePopupAssets'));
      expect(source, contains('initialData: popupInitialData'));
      expect(
        source,
        contains('initialUrlRequest: popupInitialData != null'),
        reason: 'When inline data is available, the WebView must not also '
            'navigate to assets/popup/popup.html as its main frame.',
      );
    });
  });

  group('dictionary popup scroll lifecycle', () {
    test('resets viewport scroll before rendering a new lookup', () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(source, contains('final String beforeRenderJs = isLoadMore'));
      // BUG-297 / TODO-393：换词复用热槽 WebView 时，renderPopup 之前必须先 (a) 复位
      // 视口滚动（热槽 DOM 残留旧滚动位置），(b) 归零 JS 句子上下文镜像标量（否则重建的
      // 「上 N / 下 N」选择器据残留值着色，与已清的宿主草稿不一致）。断言三者顺序：
      // __fushiResetPopupScroll → resetSentenceContextMirror → renderPopup。
      final int scrollResetAt =
          source.indexOf('window.__fushiResetPopupScroll();');
      final int mirrorResetAt =
          source.indexOf('window.resetSentenceContextMirror();');
      final int renderAt = source.indexOf('window.renderPopup();');
      expect(scrollResetAt, greaterThanOrEqualTo(0),
          reason:
              'A preserved warm popup WebView keeps its DOM scroll position. '
              'Fresh lookups must reset viewport scroll before renderPopup.');
      expect(mirrorResetAt, greaterThanOrEqualTo(0),
          reason:
              'Fresh lookups must zero the JS sentence-context mirror so the '
              'rebuilt picker matches the host-cleared draft (BUG-297).');
      expect(renderAt, greaterThan(mirrorResetAt));
      expect(mirrorResetAt, greaterThan(scrollResetAt));
      expect(
        source,
        contains("? 'window.updatePopupIncremental();'"),
        reason: 'Loading more results for the same query must keep the current '
            'scroll position instead of jumping back to the top.',
      );
    });

    test('injects popup instant-scroll preference into the caret runtime', () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(source, contains('Future<void> _pushInstantScrollPreference()'));
      expect(
        source,
        contains(
            'final bool enabled = ref.read(appProvider).popupInstantScroll'),
        reason: 'Theme/dependency changes must re-push the current preference '
            'into the already-loaded popup WebView.',
      );
      expect(source, contains('appModel.popupInstantScroll'));
      expect(
          source,
          contains(
              'final bool popupInstantScroll = appModel.popupInstantScroll'));
      expect(
        source,
        contains('ReaderCaretScripts.instantScrollInvocation('),
        reason: 'The persisted e-ink setting must be pushed into the popup '
            'WebView through the shared caret invocation builder so LB/RB and '
            'edge-follow scroll without animation when enabled.',
      );
      final int instantScrollAt = source.indexOf(
        r'${ReaderCaretScripts.instantScrollInvocation(popupInstantScroll)};',
      );
      final int renderTokenAt = source.indexOf('window.__fushiRenderToken =');
      final int resetAt =
          source.indexOf('window.__fushiResetPopupScroll = function() {');
      expect(instantScrollAt, greaterThanOrEqualTo(0));
      expect(renderTokenAt, greaterThan(instantScrollAt),
          reason: 'BUG-480 render tokens must be stamped after the shared '
              'settings / caret preference and before renderPopup().');
      expect(resetAt, greaterThan(renderTokenAt),
          reason: 'Initial result injection must set the caret scroll mode and '
              'render token before rendering or resetting the warm popup DOM.');
    });
  });

  group('dictionary popup empty-result rendering', () {
    test('empty and kanji-only results are still injected into renderPopup',
        () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(
        source,
        isNot(contains('if (widget.result.entries.isEmpty) return;')),
        reason: 'A warm popup WebView must not keep a blank/stale DOM when the '
            'lookup has zero term entries. Empty and kanji-only results must '
            'still reach popup.js renderPopup(), which renders no-results or '
            'the kanji card and emits popupRendered.',
      );

      // TODO-895 / BUG-712 ③: the entries / kanji / no-results flags live in the
      // single source of truth popup_settings_injection.dart.
      final String injection = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();

      final int entriesAt = injection.indexOf('window.lookupEntries =');
      final int kanjiAt = injection.indexOf('window.kanjiResults =');
      final int noResultsAt = injection.indexOf('window._noResultsMessage =');
      expect(entriesAt, greaterThanOrEqualTo(0));
      expect(noResultsAt, greaterThanOrEqualTo(0));
      expect(kanjiAt, greaterThan(entriesAt),
          reason: 'kanji results ride alongside the term entries in the shared '
              'entries payload, not a separate code path.');

      final int pushStart = source.indexOf('void _pushResults()');
      expect(pushStart, greaterThanOrEqualTo(0));
      final String pushBody = source.substring(pushStart);

      // BUG-712 ③ / BUG-717 ③：in-app 推送把负载分成「每次必发」与「变了才发」两
      // 类。这里钉的是**契约语义**而不是某一版的模板文本——BUG-717 ③ 已把三元条件
      // 从模板插值（`\${staticChanged ? staticSettingsJs : ''}`）上提到赋值处
      // （`\$staticSettingsJs` + 条件在 staticSettingsJs 的定义里），钉字面量的守卫
      // 只会随重构假红。真正不能变的两件事：
      //   (a) 静态设置负载受「本次产物 revision != 上次已发 revision」门控，未变时
      //       负载为空串（不重发 MB 级串），且门控命中后必须推进已发 revision；
      //   (b) 注入顺序 static → in-app extras → entries → beforeRender(+renderPopup)，
      //       空结果 / kanji-only 负载才能到达 renderPopup。

      // (a) 条件语义：判据是 revision 比较，不是别的东西。
      expect(
        pushBody,
        matches(RegExp(
          r'final\s+bool\s+staticChanged\s*=\s*'
          r'staticSettings\.revision\s*!=\s*_lastSentStaticRevision\s*;',
        )),
        reason: '静态段是否重发只能由产物 revision 与「上次已发 revision」的比较决定'
            '（BUG-717 ③ 用整数比较取代了 MB 级全串比对）',
      );
      // 门控命中后必须推进已发 revision，否则每次推送都重发 = 去重失效。
      expect(
        pushBody,
        matches(RegExp(
          r'if\s*\(\s*staticChanged\s*\)\s*\{\s*'
          r'_lastSentStaticRevision\s*=\s*staticSettings\.revision\s*;',
        )),
        reason: '只有真发出去时才推进 _lastSentStaticRevision——'
            '无条件推进会让下一次真变更被静默吞掉',
      );
      // 未变时负载必须是空串（两种等价写法都放行）。
      expect(
        pushBody,
        matches(RegExp(
          r'final\s+String\s+staticSettingsJs\s*=\s*(?:'
          r"staticChanged\s*\?\s*staticSettings\.combined\s*:\s*''"
          r"|!staticChanged\s*\?\s*''\s*:\s*staticSettings\.combined"
          r')\s*;',
        )),
        reason: '静态段未变时注入串必须为空——把 staticSettings.combined 无条件塞进'
            '推送就等于回退到「每次查词重发整段设置」',
      );

      // (b) 注入顺序：只看真正下发的那段模板，避免被声明顺序蒙混。
      final int evalAt =
          pushBody.indexOf('_controller!.evaluateJavascript(source:');
      expect(evalAt, greaterThanOrEqualTo(0));
      final String evalTemplate = pushBody.substring(evalAt);
      final int staticAt = evalTemplate.indexOf(r'$staticSettingsJs');
      final int extrasAt = evalTemplate.indexOf(r'$inAppExtrasJs');
      final int entriesJsAt = evalTemplate.indexOf(r'$entriesJs');
      final int beforeRenderAt = evalTemplate.indexOf(r'$beforeRenderJs');
      expect(staticAt, greaterThanOrEqualTo(0),
          reason:
              'the (conditional) static settings payload must be emitted into '
              'the WebView push');
      expect(extrasAt, greaterThan(staticAt),
          reason: 'BUG-717 ③ 的 in-app 固定块（重置钩子 / 句子上下文 i18n）跟在静态'
              '段之后，同属「变了才发」的一半');
      expect(entriesJsAt, greaterThan(extrasAt),
          reason: 'the entries/kanji/no-results payload must be emitted into '
              'EVERY WebView push, after the (conditional) static payloads');
      expect(beforeRenderAt, greaterThan(entriesJsAt),
          reason: 'both payloads must precede the load-more / scroll-reset '
              'beforeRenderJs so empty and kanji-only payloads reach '
              'renderPopup().');
      expect(pushBody, contains('window.renderPopup();'));
    });

    test('visible refresh queues until popup.html is ready', () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(source, contains('bool _refreshWhenReady = false;'));
      expect(
        source,
        contains(
            'if (_controller == null || !_ready) {\n      _refreshWhenReady = true;\n      return;\n    }'),
        reason: 'BUG-480: a visible warm slot can request a re-render before '
            'popup.html has finished loading; that request must be queued '
            'instead of dropped.',
      );
      // BUG-712 P1：refreshCurrentResult 从 void 改为返回 bool（false=当前结果已
      // 渲染完成、popupRendered 不会再来，宿主必须立即按已渲染处理；true=在途或
      // 已补推）。行为守卫见 dictionary_popup_push_dedup_test.dart。
      expect(source, contains('bool refreshCurrentResult()'));
      expect(
        source,
        contains('_refreshWhenReady = true;\n    _pushResults();'),
        reason: 'The host-triggered visible refresh must either run now or be '
            'replayed by the loadStop push.',
      );
      expect(
        source,
        contains('if (_refreshWhenReady || _lastSearchTerm == null) {'),
        reason: 'loadStop must consume a queued visible refresh instead of '
            'relying on an unrelated unconditional initial push.',
      );
      expect(source, contains('_refreshWhenReady = false;'),
          reason: 'A successful push must clear the queued refresh flag.');
    });
  });

  group('DictionaryPopupWebViewState.buildLookupEntriesJson', () {
    test('merges frequency and pitch metadata across grouped entries', () {
      final result = DictionarySearchResult(
        searchTerm: '食べる',
        entries: [
          DictionaryEntry(
            dictionaryName: 'TermDict',
            word: '食べる',
            reading: 'たべる',
            meaning: jsonEncode(['to eat']),
          ),
          DictionaryEntry(
            dictionaryName: 'MetadataDict',
            word: '食べる',
            reading: 'たべる',
            meaning: jsonEncode(['metadata carrier']),
            extra: jsonEncode({
              'frequencies': [
                {
                  'dictName': 'BCCWJ',
                  'values': [
                    {'value': 500, 'display': '500'},
                  ],
                },
              ],
              'pitches': [
                {
                  'dictName': 'NHK',
                  'positions': [2],
                },
              ],
            }),
          ),
        ],
      );

      final json = DictionaryPopupWebViewState.buildLookupEntriesJson(result);
      final entries = jsonDecode(json) as List<dynamic>;
      final entry = entries.single as Map<String, dynamic>;

      expect(entry['frequencies'], [
        {
          'dictionary': 'BCCWJ',
          'frequencies': [
            {'value': 500, 'displayValue': '500'},
          ],
        },
      ]);
      expect(entry['pitches'], [
        {
          'dictionary': 'NHK',
          'pitchPositions': [2],
          // 79c55c2 二期：pattern 式 accent 平行数组（数字位词典恒空）。
          'patterns': <String>[],
          // TODO-687 block3: pitch entries now always carry a transcriptions
          // list (empty for plain pitch-accent dicts, populated for IPA dicts).
          'transcriptions': <String>[],
        },
      ]);
    });

    test('deduplicates identical frequencies from multiple entries', () {
      final result = DictionarySearchResult(
        searchTerm: '見る',
        entries: [
          DictionaryEntry(
            dictionaryName: 'DictA',
            word: '見る',
            reading: 'みる',
            meaning: jsonEncode(['to see']),
            extra: jsonEncode({
              'frequencies': [
                {
                  'dictName': 'BCCWJ',
                  'values': [
                    {'value': 100, 'display': '100'},
                  ],
                },
              ],
              'pitches': [],
            }),
          ),
          DictionaryEntry(
            dictionaryName: 'DictB',
            word: '見る',
            reading: 'みる',
            meaning: jsonEncode(['to look']),
            extra: jsonEncode({
              'frequencies': [
                {
                  'dictName': 'BCCWJ',
                  'values': [
                    {'value': 100, 'display': '100'},
                  ],
                },
              ],
              'pitches': [],
            }),
          ),
        ],
      );

      final json = DictionaryPopupWebViewState.buildLookupEntriesJson(result);
      final entries = jsonDecode(json) as List<dynamic>;
      final entry = entries.single as Map<String, dynamic>;

      expect(entry['glossaries'], hasLength(2));
      expect(entry['frequencies'], hasLength(1));
    });
  });

  group('buildPopupJsonFromLookup parity', () {
    List<FushiLookupResult> makeLookupResults() {
      return [
        FushiLookupResult(
          matched: '食べた',
          deinflected: '食べる',
          trace: [],
          preprocessorSteps: 0,
          term: FushiTermResult(
            expression: '食べる',
            reading: 'たべる',
            rules: '',
            glossaries: [
              FushiGlossaryEntry(
                dictName: 'JMdict',
                glossary: jsonEncode(['to eat', 'to consume']),
                definitionTags: 'v1',
                termTags: 'common',
              ),
              FushiGlossaryEntry(
                dictName: '大辞泉',
                glossary: jsonEncode({
                  'tag': 'div',
                  'content': [
                    {'tag': 'span', 'content': '食べること'}
                  ],
                }),
                definitionTags: '',
                termTags: '',
              ),
            ],
            frequencies: [
              FushiFrequencyEntry(
                dictName: 'BCCWJ',
                frequencies: [
                  FushiFrequency(value: 500, displayValue: '500'),
                  FushiFrequency(value: 0, displayValue: 'Top 500'),
                ],
              ),
            ],
            pitches: [
              FushiPitchEntry(
                  dictName: 'NHK', pitchPositions: [2], patterns: ['heiban']),
              // IPA transcription dict: no pitch positions, only transcriptions.
              // Exercises the TODO-687 block3 passthrough end to end.
              FushiPitchEntry(
                dictName: 'IPA',
                pitchPositions: [],
                transcriptions: ['taꜜbeɾɯ', 'tabeɾu'],
              ),
            ],
          ),
        ),
        FushiLookupResult(
          matched: '食べた',
          deinflected: '食べる',
          trace: [],
          preprocessorSteps: 0,
          term: FushiTermResult(
            expression: '食べる',
            reading: 'たべる',
            rules: '',
            glossaries: [
              FushiGlossaryEntry(
                dictName: 'Kenkyusha',
                glossary: jsonEncode('eat; consume'),
                definitionTags: '',
                termTags: '',
              ),
            ],
            frequencies: [
              FushiFrequencyEntry(
                dictName: 'JPDB',
                frequencies: [
                  FushiFrequency(value: 120, displayValue: '#120'),
                ],
              ),
            ],
            pitches: [
              FushiPitchEntry(
                  dictName: 'NHK', pitchPositions: [2], patterns: ['heiban']),
              FushiPitchEntry(
                dictName: 'IPA',
                pitchPositions: [],
                transcriptions: ['taꜜbeɾɯ', 'tabeɾu'],
              ),
            ],
          ),
        ),
      ];
    }

    test('produces structurally equivalent JSON to buildLookupEntriesJson', () {
      final lookupResults = makeLookupResults();
      const maxTerms = 100;

      final newJson = buildPopupJsonFromLookup(
        results: lookupResults,
        maximumTerms: maxTerms,
      );
      final oldResult = buildResultFromLookup(
        searchTerm: '食べた',
        results: lookupResults,
        maximumTerms: maxTerms,
      );
      final oldJson =
          DictionaryPopupWebViewState.buildLookupEntriesJson(oldResult);

      final newParsed = jsonDecode(newJson) as List;
      final oldParsed = jsonDecode(oldJson) as List;

      expect(newParsed.length, oldParsed.length);

      for (var i = 0; i < newParsed.length; i++) {
        final n = newParsed[i] as Map<String, dynamic>;
        final o = oldParsed[i] as Map<String, dynamic>;

        expect(n['expression'], o['expression']);
        expect(n['reading'], o['reading']);
        expect(n['matched'], o['matched']);

        final nGloss = n['glossaries'] as List;
        final oGloss = o['glossaries'] as List;
        expect(nGloss.length, oGloss.length);
        for (var j = 0; j < nGloss.length; j++) {
          expect(nGloss[j]['dictionary'], oGloss[j]['dictionary']);
          expect(nGloss[j]['content'], oGloss[j]['content']);
          expect(nGloss[j]['definitionTags'], oGloss[j]['definitionTags']);
          expect(nGloss[j]['termTags'], oGloss[j]['termTags']);
        }

        final nFreqs = n['frequencies'] as List;
        final oFreqs = o['frequencies'] as List;
        expect(nFreqs.length, oFreqs.length);
        for (var j = 0; j < nFreqs.length; j++) {
          expect(nFreqs[j]['dictionary'], oFreqs[j]['dictionary']);
          expect(nFreqs[j]['frequencies'], oFreqs[j]['frequencies']);
        }

        final nPitches = n['pitches'] as List;
        final oPitches = o['pitches'] as List;
        expect(nPitches.length, oPitches.length);
        for (var j = 0; j < nPitches.length; j++) {
          expect(nPitches[j]['dictionary'], oPitches[j]['dictionary']);
          expect(nPitches[j]['pitchPositions'], oPitches[j]['pitchPositions']);
          // 79c55c2 二期：pattern 式 accent 两条路径逐字段一致。
          expect(nPitches[j]['patterns'], oPitches[j]['patterns']);
          // TODO-687 block3: transcriptions must survive both paths identically
          // (parity is field-level — adding a field never auto-fails, so this
          // assertion is hand-added together with the IPA fixture data above).
          expect(nPitches[j]['transcriptions'], oPitches[j]['transcriptions']);
        }

        // BUG-712 P4：searchDictionary 改走 Dart 侧 buildPopupJsonFromLookup 后，
        // deinflectionTrace 必须与旧路径（buildLookupEntriesJson）逐字段一致——
        // fixture 的 matched(食べた)≠deinflected(食べる) 正好覆盖非空痕迹；丢了它
        // 弹窗就不再显示「食べた → 食べる」的去屈折痕迹。
        expect(n['deinflectionTrace'], o['deinflectionTrace']);
      }
    });

    test(
        'deinflectionTrace: single "matched → deinflected" step, '
        'only when they differ and deinflected is non-empty', () {
      // 与 C++ build_popup_json（native/fushidicts/fushidicts_src/popup_json.cpp）
      // 语义对齐：仅在 matched != deinflected 且 deinflected 非空时生成**单条**
      // {"name":"matched → deinflected","description":""}，否则为空数组。
      FushiLookupResult make({
        required String matched,
        required String deinflected,
      }) =>
          FushiLookupResult(
            matched: matched,
            deinflected: deinflected,
            trace: [],
            preprocessorSteps: 0,
            term: FushiTermResult(
              expression: '食べる',
              reading: 'たべる',
              rules: '',
              glossaries: [
                FushiGlossaryEntry(
                  dictName: 'JMdict',
                  glossary: jsonEncode(['to eat']),
                  definitionTags: '',
                  termTags: '',
                ),
              ],
              frequencies: [],
              pitches: [],
            ),
          );

      // ① 屈折命中（matched≠deinflected 且非空）→ 恰好一条痕迹。
      final withTrace = jsonDecode(buildPopupJsonFromLookup(
        results: [make(matched: '食べた', deinflected: '食べる')],
        maximumTerms: 100,
      )) as List;
      expect((withTrace.single as Map<String, dynamic>)['deinflectionTrace'], [
        {'name': '食べた → 食べる', 'description': ''},
      ]);

      // ② 原形直查（matched == deinflected）→ 空数组，不生成自指痕迹。
      final noInflection = jsonDecode(buildPopupJsonFromLookup(
        results: [make(matched: '食べる', deinflected: '食べる')],
        maximumTerms: 100,
      )) as List;
      expect(
        (noInflection.single as Map<String, dynamic>)['deinflectionTrace'],
        isEmpty,
      );

      // ③ 引擎未回填 deinflected（空串）→ 同样空数组，不生成「x → 」残缺痕迹。
      final emptyDeinflected = jsonDecode(buildPopupJsonFromLookup(
        results: [make(matched: '食べた', deinflected: '')],
        maximumTerms: 100,
      )) as List;
      expect(
        (emptyDeinflected.single as Map<String, dynamic>)['deinflectionTrace'],
        isEmpty,
      );

      // ④ 与旧路径（buildResultFromLookup → buildLookupEntriesJson，即 P4 换掉的
      //    渲染真值）对同一输入产出完全一致的痕迹。
      final oldParsed = jsonDecode(
        DictionaryPopupWebViewState.buildLookupEntriesJson(
          buildResultFromLookup(
            searchTerm: '食べた',
            results: [make(matched: '食べた', deinflected: '食べる')],
            maximumTerms: 100,
          ),
        ),
      ) as List;
      expect(
        (oldParsed.single as Map<String, dynamic>)['deinflectionTrace'],
        [
          {'name': '食べた → 食べる', 'description': ''},
        ],
      );
    });

    // BUG-1472：maximumTerms 的单位是**词头卡**，不是 glossary 注释行。
    // 这个 fixture 是同一个词头（食べる/たべる）跨两本词典共 3 条注释——旧断言
    // 「maximumTerms=2 ⇒ 只剩 2 条注释」把 bug 本身写成了契约：用户会静默丢掉
    // 第三本词典的释义，而真正该被上限约束的「还有几个别的读音/表记」反而不受控。
    test('maximumTerms 约束词头卡数，不腰斩单个词头的注释', () {
      final lookupResults = makeLookupResults();
      final json = buildPopupJsonFromLookup(
        results: lookupResults,
        maximumTerms: 2,
      );
      final parsed = jsonDecode(json) as List;
      expect(parsed.length, 1, reason: '两条结果同属一个词头，只该出一张卡');
      final entry = parsed.single as Map<String, dynamic>;
      expect(
        (entry['glossaries'] as List).length,
        3,
        reason: '同一个词头的三本词典释义必须全在——按注释行计预算会砍掉第三本',
      );
    });

    test('maximumTerms 真的截断词头卡数', () {
      final json = buildPopupJsonFromLookup(
        results: <FushiLookupResult>[
          ...makeLookupResults(),
          FushiLookupResult(
            matched: '食べた',
            deinflected: '食べる',
            trace: const [],
            preprocessorSteps: 0,
            term: FushiTermResult(
              expression: '喰べる',
              reading: 'くべる',
              rules: '',
              glossaries: [
                FushiGlossaryEntry(
                  dictName: '大辞林',
                  glossary: jsonEncode('別表記・別読み'),
                  definitionTags: '',
                  termTags: '',
                ),
              ],
              frequencies: const [],
              pitches: const [],
            ),
          ),
        ],
        maximumTerms: 1,
      );
      expect((jsonDecode(json) as List).length, 1);
    });

    test('returns empty array for empty results', () {
      final json = buildPopupJsonFromLookup(results: [], maximumTerms: 100);
      expect(json, '[]');
    });
  });

  // TODO-896 源码守卫：查词弹窗两交互修复。整页 widget 测试依赖真实平台 WebView
  // （测试宿主的 fake 平台渲染空盒、不进手势竞技场、无原生右键菜单），故按既有 popup
  // 守卫范式在源码层钉死结构不变量；几何对齐（界面大小≠100% 时右键对准鼠标）+ 框选
  // 不关窗的真实行为只能 Windows 真机肉眼验，自动化测不到。
  group('TODO-896 popup gesture / context-menu source guards', () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();

    test('症状①：WebView 声明 HorizontalDragGestureRecognizer 争正文区水平拖', () {
      // 没有它，包住整张 surface 的 _BodySwipeDismissDetector（TODO-880 本体横拖关）
      // 会赢走正文区框选的水平位移→误关弹窗（BUG-299 隔离被打穿）。
      expect(
        source,
        contains('Factory<HorizontalDragGestureRecognizer>('),
        reason: '正文区水平拖（框选）必须归 WebView，否则被 body-swipe detector '
            '判成滑动关闭（症状①）。',
      );
      // 与 LongPress / VerticalDrag 并列在同一个 gestureRecognizers 集合里。
      final int setStart = source.indexOf(
          'gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{');
      expect(setStart, greaterThanOrEqualTo(0));
      final int setEnd = source.indexOf('},', setStart);
      expect(setEnd, greaterThan(setStart));
      final String setBody = source.substring(setStart, setEnd);
      expect(setBody.contains('LongPressGestureRecognizer'), isTrue);
      expect(setBody.contains('VerticalDragGestureRecognizer'), isTrue);
      expect(setBody.contains('HorizontalDragGestureRecognizer'), isTrue,
          reason: '三个识别器必须同集合并列声明');
    });

    test('症状②：Windows 禁原生菜单 + 走 Flutter showMenu（BUG-261 锚点范式）', () {
      // 原生 WebView2 菜单只在 Windows 偏移（独立 Win32 popup 用未拉伸逻辑坐标），
      // Windows 禁原生改 Flutter 菜单；Android 因 BUG-1237 的 ActionMode 转发缺陷
      // 也隐藏系统项、改由 Dart 直做。iOS 不扩范围，保持原生。
      expect(
        source,
        contains('Platform.isAndroid || isWindowsPlatform'),
        reason: 'Windows 与 Android 各自按真实原生缺陷禁系统项；iOS 保持原生。',
      );
      // 右键入口 onSecondaryTapDown，仅 Windows 包 GestureDetector。
      expect(source, contains('onSecondaryTapDown:'),
          reason: '桌面右键经 GestureDetector.onSecondaryTapDown 进入 Flutter 菜单');
      expect(source, contains('if (isWindowsPlatform) {'),
          reason: '右键 GestureDetector 包裹仅在 Windows 生效，其它平台返回裸 WebView');

      // 窗口由花括号配对给出，不再是 `menuStart + 1800` 的定长切片：该方法体实测
      // 1671 字符，旧窗口一头越界读进后面的 static 成员，另一头只给末尾的
      // Clipboard 断言留 ~180 字符余量——方法里多写四行就凭空变红。
      final String body =
          methodBody(source, 'Future<void> _showWindowsContextMenu(');
      // BUG-261/260 锚点范式：取 showMenu 所用 Overlay 的 RenderBox，把右键点映射到该
      // Overlay 坐标系（吃掉界面大小 FittedBox 缩放残差），再据 Overlay 尺寸算 RelativeRect。
      expect(body.contains('Overlay.of(context).context.findRenderObject()'),
          isTrue,
          reason: '锚点须落在 showMenu 所用 Overlay 坐标系（取该 Overlay 的 RenderBox）');
      expect(
          body.contains('overlayObject.globalToLocal(globalPosition)'), isTrue,
          reason: '右键 globalPosition 沿真实渲染链映射到 Overlay 空间（吸收缩放残差）');
      expect(body.contains('RelativeRect.fromLTRB('), isTrue,
          reason: '右键位置转 RelativeRect 作菜单锚点');
      expect(body.contains('overlaySize.width - anchor.dx'), isTrue,
          reason: 'right/bottom 以 Overlay 尺寸算，与 anchor 同系（缩放画布空间）');
      expect(body.contains('showMenu<_PopupContextMenuAction>('), isTrue,
          reason: '用 Flutter showMenu 弹 Hibiki 自绘菜单');
    });

    test('症状②：Flutter 菜单含「查词」+「复制」两项（复制走 BUG-402 范式）', () {
      // 同上：窗口=方法体（花括号配对），与方法长度无关。
      final String body =
          methodBody(source, 'Future<void> _showWindowsContextMenu(');
      // 「查词」平移自原 WebView2 自定义项；「复制」是原 WebView2 原生项，禁原生后自补。
      expect(body.contains('_PopupContextMenuAction.search'), isTrue,
          reason: '保留「查词」项（平移自原 WebView2 自定义项）');
      expect(body.contains('t.search'), isTrue);
      expect(body.contains('_PopupContextMenuAction.copy'), isTrue,
          reason: '「复制」必须自补（原是 WebView2 原生项，禁原生后丢失）');
      expect(body.contains('t.copy'), isTrue);
      // 复制/搜索取选区文本 + Clipboard.setData（BUG-402）。BUG-802：选区读取从早年的
      // getSelectedText（桌面 fork 未实现 + 只读顶层文档取不到词条卡 iframe 内选区）改为
      // 穿透同源 iframe 的 _selectedTextAcrossFrames，否则复制/搜索永远拿空串无效。
      expect(body.contains('_selectedTextAcrossFrames()'), isTrue,
          reason: '复制/搜索经穿透 iframe 的 _selectedTextAcrossFrames 取选区（BUG-802）');
      // BUG-1451：写剪贴板从方法体内联收口到共用 `_copySelectionToClipboard`（三条复制
      // 入口 —— Windows 右键菜单 / Windows Ctrl+C / Android 原生菜单 —— 统一走它，带成功
      // 反馈）。不变式没变（右键复制最终把选区写系统剪贴板），只是落点变了；「全文件裸
      // Clipboard.setData 只许出现一处」这条更强的守卫在
      // test/pages/popup_copy_shortcut_and_menu_guard_test.dart。
      expect(body.contains('_copySelectionToClipboard(text)'), isTrue,
          reason: '把选区文本写系统剪贴板（BUG-402 范式，经 BUG-1451 收口的共用 helper）');
      expect(source.contains('Clipboard.setData(ClipboardData(text: text))'),
          isTrue,
          reason: 'helper 内必须真的写系统剪贴板');
    });
  });
}
