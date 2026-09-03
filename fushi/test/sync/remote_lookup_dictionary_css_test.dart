import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_api_handlers.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// BUG-1718 守卫：`/api/lookup/dictionary` 必须把「弹窗 CSS 尾段」（词典包自带 styles.css +
/// 用户全局/单典自定义 CSS）下发给浏览器扩展，且必须走 revision 门控。
///
/// 背景：app 内查词弹窗与浏览器扩展跑的是同一份 `popup.js`，它读 `window.dictionaryStyles` /
/// `globalDictCSS` / `customDictCSS` 渲染样式。app 内由 popup_settings_injection 注入，扩展
/// 只能随查词响应拿——历史上这条通道根本不存在，于是 mdx 词典的自带样式在扩展里 100% 失效
/// （用户症状：同一本 OALDPE，视频内查词有徽标/音标配色/义项缩进，浏览器插件里全是裸文本）。
///
/// 同时它体量大（实测整库 285 KB），绝不能每次 hover 查词都传，故：
///  - 请求体没有 `stylesRevision` 键 ⇒ 老客户端，一个字节都不发（向后兼容）；
///  - 有键且指纹不一致 ⇒ 全量下发一次；
///  - 有键且指纹一致 ⇒ 只回指纹。
class _StubLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async =>
      DictionarySearchResult(searchTerm: term, bestLength: term.length);

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async =>
      null;
}

RemotePopupDictionaryCss _css({
  Map<String, String>? styles,
  String global = '',
  Map<String, String>? custom,
}) =>
    RemotePopupDictionaryCss(
      dictionaryStyles:
          styles ?? <String, String>{'OALDPE': '.opal{color:red}'},
      globalDictCss: global,
      customDictCss: custom ?? <String, String>{},
    );

Future<Map<String, dynamic>> _lookup(
  Map<String, dynamic> body, {
  RemotePopupDictionaryCss? css,
}) =>
    buildRemoteDictionaryLookupResponse(
      body,
      lookup: _StubLookup(),
      popupDictionaryCssProvider: css == null ? null : () => css,
    );

void main() {
  group('BUG-1718 弹窗 CSS 尾段下发', () {
    test('未注入供给器时响应完全不变（sync host / 老部署）', () async {
      final Map<String, dynamic> r =
          await _lookup(<String, dynamic>{'term': '猫'});
      expect(r.containsKey('dictionaryStylesRevision'), isFalse);
      expect(r.containsKey('dictionaryStyles'), isFalse);
      expect(r.containsKey('globalDictCSS'), isFalse);
      expect(r.containsKey('customDictCSS'), isFalse);
    });

    test('请求没有 stylesRevision 键 ⇒ 只带指纹，不带正文（老扩展不被灌 285 KB）', () async {
      final RemotePopupDictionaryCss css = _css();
      final Map<String, dynamic> r =
          await _lookup(<String, dynamic>{'term': '猫'}, css: css);
      expect(r['dictionaryStylesRevision'], css.revision);
      expect(r.containsKey('dictionaryStyles'), isFalse,
          reason: '未声明支持该契约的客户端不得收到词典 CSS 正文');
    });

    test('指纹不一致 ⇒ 三件套全量下发', () async {
      final RemotePopupDictionaryCss css = _css(
        global: 'body{font-size:16px}',
        custom: <String, String>{'明鏡': '.mk{color:blue}'},
      );
      final Map<String, dynamic> r = await _lookup(
        <String, dynamic>{'term': '猫', 'stylesRevision': null},
        css: css,
      );
      expect(r['dictionaryStylesRevision'], css.revision);
      expect(r['dictionaryStyles'], css.dictionaryStyles);
      expect(r['globalDictCSS'], 'body{font-size:16px}');
      expect(r['customDictCSS'], css.customDictCss);
    });

    test('指纹一致 ⇒ 只回指纹（命中客户端缓存）', () async {
      final RemotePopupDictionaryCss css = _css();
      final Map<String, dynamic> r = await _lookup(
        <String, dynamic>{'term': '猫', 'stylesRevision': css.revision},
        css: css,
      );
      expect(r['dictionaryStylesRevision'], css.revision);
      expect(r.containsKey('dictionaryStyles'), isFalse);
    });

    test('popupOnly 快路径与空词请求同样带上这套字段（扩展默认走 popupOnly）', () async {
      final RemotePopupDictionaryCss css = _css();
      final Map<String, dynamic> fast = await _lookup(
        <String, dynamic>{
          'term': '猫',
          'popupOnly': true,
          'stylesRevision': 'x'
        },
        css: css,
      );
      expect(fast['dictionaryStyles'], css.dictionaryStyles);
      final Map<String, dynamic> empty = await _lookup(
        <String, dynamic>{'term': '', 'stylesRevision': css.revision},
        css: css,
      );
      expect(empty['dictionaryStylesRevision'], css.revision);
    });

    // ── 接线守卫：光有服务端契约没用，三镜像的消费端必须真的接上 ───────────────
    //
    // 这条通道横跨 Dart（供给器 → server）与 JS（background 缓存 → content/side-panel →
    // popup.js 全局），任何一环被重构悄悄拆掉，用户看到的都是「插件里词典没样式」这同一个
    // 症状，而单测/analyze 全绿。故按源码存在性钉死每一环。
    test(
        'app 侧把 CSS 尾段供给器接到扩展 server 上（app_model → manager → server → handler）',
        () {
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(appModel, contains('popupDictionaryCssProvider:'),
          reason:
              'app_model 没把 popupDictionaryCssProvider 交给 YomitanApiServerManager');
      expect(appModel, contains('browserExtensionPopupDictionaryCss'),
          reason: 'app_model 缺 CSS 尾段供给器实现');
      final String manager =
          File('lib/src/sync/yomitan_api_server_manager.dart')
              .readAsStringSync();
      expect(manager, contains('popupDictionaryCssProvider'),
          reason: 'manager 没把供给器透传给 YomitanApiServer');
      final String server =
          File('lib/src/sync/yomitan_api_server.dart').readAsStringSync();
      expect(server,
          contains('popupDictionaryCssProvider: _popupDictionaryCssProvider'),
          reason: 'YomitanApiServer 没把供给器交给共享 handler');
    });

    test('扩展两镜像都接上了 CSS 尾段与词条资源占位的兑现方', () {
      const Map<String, String> mirrors = <String, String>{
        'assets': 'assets/browser_extension',
        'tools': '../tools/browser-extension',
      };
      mirrors.forEach((String name, String root) {
        final String dictMedia =
            File('$root/vendor/dict-media.js').readAsStringSync();
        expect(dictMedia, contains('function applyFushiPopupCss('),
            reason: '[$name] dict-media.js 缺 CSS 尾段落地函数');
        expect(dictMedia, contains('function resolveDictMediaPlaceholders('),
            reason: '[$name] dict-media.js 缺占位兑现函数（缺它 = mdx 词条插图恒裂图）');
        expect(dictMedia,
            contains('function installDictMediaPlaceholderResolver('),
            reason: '[$name] dict-media.js 缺占位兑现的 MutationObserver 安装函数');

        final String background =
            File('$root/background.js').readAsStringSync();
        expect(background, contains('stylesRevision: fushiPopupCss.revision'),
            reason: '[$name] background.js 没把已缓存指纹带进查词请求 '
                '⇒ 服务端每次查词都要回全量（数百 KB）或永远不回');
        expect(background, contains('fushiMergePopupCss(data)'),
            reason: '[$name] background.js 没把 CSS 尾段并进缓存并回填给页面');

        final String content = File('$root/content.js').readAsStringSync();
        // 两处：首次查词渲染 + 嵌套查词渲染。只数「有没有」会被另一处顶着，删掉其中一处
        // 照样绿（实测：删首次查词那处，contains 仍命中嵌套那处）——所以必须数够 2 次。
        expect('applyFushiPopupCss(resp.data)'.allMatches(content).length, 2,
            reason: '[$name] content.js 的首次查词 / 嵌套查词两条渲染路径都必须落 CSS 尾段');
        expect(content, contains('installDictMediaPlaceholderResolver(shadow)'),
            reason: '[$name] content.js 没在弹窗 shadow 上装占位兑现器');

        final String sidePanel = File('$root/side-panel.js').readAsStringSync();
        expect(sidePanel, contains('applyFushiPopupCss(data)'),
            reason: '[$name] side-panel.js 没落 CSS 尾段');
        expect(sidePanel,
            contains('installDictMediaPlaceholderResolver(lookupShadow)'),
            reason: '[$name] side-panel.js 没装占位兑现器');
      });
    });

    test('内容变了指纹必须变——否则用户导入/删词典后扩展永远用陈旧样式', () {
      final RemotePopupDictionaryCss base = _css();
      expect(
        _css(styles: <String, String>{'OALDPE': '.opal{color:blue}'}).revision,
        isNot(base.revision),
        reason: '同名词典换了 CSS 内容',
      );
      expect(
        _css(styles: <String, String>{
          'OALDPE': '.opal{color:red}',
          '明鏡': '.mk{}',
        }).revision,
        isNot(base.revision),
        reason: '新增一本词典',
      );
      expect(_css(global: '.g{}').revision, isNot(base.revision),
          reason: '用户改全局自定义 CSS');
      expect(_css(custom: <String, String>{'明鏡': '.c{}'}).revision,
          isNot(base.revision),
          reason: '用户改单典自定义 CSS');
      expect(_css().revision, base.revision,
          reason: '同内容必须得到同指纹，否则每次查词都白传一次全量');
    });
  });
}
