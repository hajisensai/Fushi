import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

void main() {
  group('dictionary popup scroll lifecycle', () {
    test('resets viewport scroll before rendering a new lookup', () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(source, contains('final String beforeRenderJs = isLoadMore'));
      // BUG-297 / TODO-393：换词复用热槽 WebView 时，renderPopup 之前必须先 (a) 复位
      // 视口滚动（热槽 DOM 残留旧滚动位置），(b) 归零 JS 句子上下文镜像标量（否则重建的
      // 「上 N / 下 N」选择器据残留值着色，与已清的宿主草稿不一致）。断言三者顺序：
      // __hoshiResetPopupScroll → resetSentenceContextMirror → renderPopup。
      final int scrollResetAt =
          source.indexOf('window.__hoshiResetPopupScroll();');
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
      expect(
        source,
        contains(
            '      \${ReaderCaretScripts.instantScrollInvocation(popupInstantScroll)};\n'
            '      window.__hoshiResetPopupScroll = function() {'),
        reason:
            'Initial result injection must set the caret scroll mode before '
            'rendering or resetting the warm popup DOM.',
      );
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

      // TODO-895: the entries / kanji / no-results flags moved into the single
      // source of truth buildPopupSettingsJs (popup_settings_injection.dart),
      // which _pushResults emits as `$sharedSettingsJs` BEFORE its own load-more
      // vs scroll-reset `$beforeRenderJs` + renderPopup(). Verify the ordering
      // across both halves so empty / kanji-only payloads still reach renderPopup.
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
              'settings body, not a separate code path.');

      final int pushStart = source.indexOf('void _pushResults()');
      expect(pushStart, greaterThanOrEqualTo(0));
      final String pushBody = source.substring(pushStart);

      final int sharedAt = pushBody.indexOf(r'$sharedSettingsJs');
      final int beforeRenderAt = pushBody.indexOf(r'$beforeRenderJs');
      expect(sharedAt, greaterThanOrEqualTo(0),
          reason: 'the shared settings body (entries/kanji/no-results) must be '
              'emitted into the WebView push');
      expect(beforeRenderAt, greaterThan(sharedAt),
          reason: 'the shared body must precede the load-more / scroll-reset '
              'beforeRenderJs so empty and kanji-only payloads reach '
              'renderPopup().');
      expect(pushBody, contains('window.renderPopup();'));
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
    List<HoshiLookupResult> makeLookupResults() {
      return [
        HoshiLookupResult(
          matched: '食べた',
          deinflected: '食べる',
          trace: [],
          preprocessorSteps: 0,
          term: HoshiTermResult(
            expression: '食べる',
            reading: 'たべる',
            rules: '',
            glossaries: [
              HoshiGlossaryEntry(
                dictName: 'JMdict',
                glossary: jsonEncode(['to eat', 'to consume']),
                definitionTags: 'v1',
                termTags: 'common',
              ),
              HoshiGlossaryEntry(
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
              HoshiFrequencyEntry(
                dictName: 'BCCWJ',
                frequencies: [
                  HoshiFrequency(value: 500, displayValue: '500'),
                  HoshiFrequency(value: 0, displayValue: 'Top 500'),
                ],
              ),
            ],
            pitches: [
              HoshiPitchEntry(dictName: 'NHK', pitchPositions: [2]),
              // IPA transcription dict: no pitch positions, only transcriptions.
              // Exercises the TODO-687 block3 passthrough end to end.
              HoshiPitchEntry(
                dictName: 'IPA',
                pitchPositions: [],
                transcriptions: ['taꜜbeɾɯ', 'tabeɾu'],
              ),
            ],
          ),
        ),
        HoshiLookupResult(
          matched: '食べた',
          deinflected: '食べる',
          trace: [],
          preprocessorSteps: 0,
          term: HoshiTermResult(
            expression: '食べる',
            reading: 'たべる',
            rules: '',
            glossaries: [
              HoshiGlossaryEntry(
                dictName: 'Kenkyusha',
                glossary: jsonEncode('eat; consume'),
                definitionTags: '',
                termTags: '',
              ),
            ],
            frequencies: [
              HoshiFrequencyEntry(
                dictName: 'JPDB',
                frequencies: [
                  HoshiFrequency(value: 120, displayValue: '#120'),
                ],
              ),
            ],
            pitches: [
              HoshiPitchEntry(dictName: 'NHK', pitchPositions: [2]),
              HoshiPitchEntry(
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
          // TODO-687 block3: transcriptions must survive both paths identically
          // (parity is field-level — adding a field never auto-fails, so this
          // assertion is hand-added together with the IPA fixture data above).
          expect(nPitches[j]['transcriptions'], oPitches[j]['transcriptions']);
        }
      }
    });

    test('respects maximumTerms limit', () {
      final lookupResults = makeLookupResults();
      final json = buildPopupJsonFromLookup(
        results: lookupResults,
        maximumTerms: 2,
      );
      final parsed = jsonDecode(json) as List;
      final entry = parsed.single as Map<String, dynamic>;
      final glossaries = entry['glossaries'] as List;
      expect(glossaries.length, 2);
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
      // 故只在 Windows 禁原生改 Flutter 菜单；非 Windows 保持原生（false 不写死）。
      expect(
        source,
        contains('hideDefaultSystemContextMenuItems: isWindowsPlatform'),
        reason: 'Windows 才禁 WebView2 原生菜单，其它平台保持原生（症状②）。',
      );
      // 右键入口 onSecondaryTapDown，仅 Windows 包 GestureDetector。
      expect(source, contains('onSecondaryTapDown:'),
          reason: '桌面右键经 GestureDetector.onSecondaryTapDown 进入 Flutter 菜单');
      expect(source, contains('if (isWindowsPlatform) {'),
          reason: '右键 GestureDetector 包裹仅在 Windows 生效，其它平台返回裸 WebView');

      final int menuStart =
          source.indexOf('Future<void> _showWindowsContextMenu(');
      expect(menuStart, greaterThan(0),
          reason: '必须有 _showWindowsContextMenu 入口');
      final String body = source.substring(menuStart, menuStart + 1800);
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
      final int menuStart =
          source.indexOf('Future<void> _showWindowsContextMenu(');
      final String body = source.substring(menuStart, menuStart + 1800);
      // 「查词」平移自原 WebView2 自定义项；「复制」是原 WebView2 原生项，禁原生后自补。
      expect(body.contains('_PopupContextMenuAction.search'), isTrue,
          reason: '保留「查词」项（平移自原 WebView2 自定义项）');
      expect(body.contains('t.search'), isTrue);
      expect(body.contains('_PopupContextMenuAction.copy'), isTrue,
          reason: '「复制」必须自补（原是 WebView2 原生项，禁原生后丢失）');
      expect(body.contains('t.copy'), isTrue);
      // 复制走 BUG-402 范式：getSelectedText + Clipboard.setData。
      expect(body.contains('_controller?.getSelectedText()'), isTrue,
          reason: '复制取选区文本（BUG-402：桌面 WebView2 原生复制键转发受限）');
      expect(
          body.contains('Clipboard.setData(ClipboardData(text: text))'), isTrue,
          reason: '把选区文本写系统剪贴板（BUG-402 范式）');
    });
  });
}
