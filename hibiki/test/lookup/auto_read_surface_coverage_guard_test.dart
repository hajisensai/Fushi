import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1210 守卫：**每一个查词表面都必须明确声明它接不接自动朗读**。
///
/// 为什么要这条：BUG-1210 的第一版只补了剪贴板面板的 `update()`（剪贴板流）一条路径，
/// 而同一个面板里 `_lookupFromBanner`（点句中字换根）和 `_lookupNested`（点释义里的词
/// 再查）两条**用户主动查词**的路径仍然不读——「复制进来会读、点字不读」，而且嵌套那条
/// 在瞬态覆盖窗上是会读的，两个表面在同一个动作上行为漂开。
///
/// 当初判成「唯一漏接」是因为**扫的方向反了**：从 `autoRead` 符号侧去找调用点，只能看见
/// 「已经调了朗读的地方」，天生看不见「没调的路径」——那是循环论证。正确的方向是从
/// **查词结果的产生侧**穷举：所有查词表面最终都经 `AppModel.searchDictionary(`，把它的
/// 全部调用点列出来，逐个要求声明。本守卫把这个方向固化下来。
///
/// 守的是：**新增一个查词表面时，必须在下面两张表之一里显式声明**，否则测试红。
/// 不守的是：同一个文件里**新增调用点**（表按文件粒度；行号粒度会随重构漂移、变成噪音）。
/// 这个局限是有意的取舍，不是疏漏。
///
/// flutter test 的 cwd 是 hibiki 包根。
void main() {
  /// 已接自动朗读的查词表面：路径 → 接线位置。
  /// 这里的每一项都会被**正向验证**（文件里真的要有朗读调用），防止名单过期成橡皮图章。
  const Map<String, String> wiredSurfaces = <String, String>{
    'lib/src/lookup/global_lookup_controller.dart':
        'app 外瞬态查词覆盖窗：lookupText 与 _lookupNested 两条路径末尾各调 '
            '_autoReadFirstEntry（委托共享 OverlayAutoRead）。',
    'lib/src/lookup/clipboard_panel_controller.dart':
        'app 外常驻剪贴板面板：update()（剪贴板流）/ _lookupFromBanner（点字换根）/ '
            '_lookupNested（嵌套查词）三条路径均调 _autoRead.autoReadFirstEntry。'
            '前两条在 _renderPanel 之后还要核对 latest-wins 序号才朗读。',
    'lib/src/pages/base_source_page.dart':
        'app 内媒体页：查词后读 autoReadOnLookup 偏好并调 _autoReadWord。',
    'lib/src/pages/implementations/home_dictionary_page.dart':
        'app 内词典主页：除 mixin 的 searchPopup 外自己也直接查词（_performSearch），'
            '命中后按 autoRead ?? autoReadOnLookup 调 autoReadWord。剪贴板注入那条路径'
            '显式传 autoRead: false，是有意覆盖（避免被动注入时突然出声），不是漏接。',
    'lib/src/pages/implementations/dictionary_page_mixin.dart':
        'app 内词典页 mixin：searchPopup(autoRead:) 决定是否调 autoReadWord。'
            '五个消费方（home_dictionary / popup_dictionary / texthooker / '
            'floating_lyric_lookup_host / video_hibiki_page）均传 autoRead: true。',
  };

  /// 豁免的查词调用点：路径 → **具体**理由。
  /// 理由必须说清「为什么这里不该自动出声」，不能只写个文件名或「不需要」——
  /// 只有文件名的白名单过两个月就会退化成「往里塞一行」的橡皮图章。
  const Map<String, String> exemptCallSites = <String, String>{
    'lib/src/models/app_model.dart':
        '三类都不是查词表面：① 启动与切 profile 时的预热（Future.wait 里的 '
            'searchDictionary，没有任何 UI 呈现）；② _searchRemoteDictionary 是 '
            'searchDictionary 自己的远端分支，不是独立入口；③ '
            '_setupFloatingDictHandlers.onSearch 是 Android 悬浮词典的 native 通道 '
            'handler——**待产品拍板**，见下面 floating_dict_page 那条同一取舍。',
    'lib/src/pages/implementations/floating_dict_page.dart':
        'Android 悬浮词典页的搜索框查词。同为「手动输入」的 home_dictionary_page 是朗读的，'
            '故行为并不一致；但悬浮词典是浮在别的 app 上层的小窗，突然出声更打扰，'
            '该不该自动朗读是产品取舍——**待产品拍板**，定了再从本表挪进 wiredSurfaces。',
    'lib/src/pages/implementations/home_page.dart':
        'resumed 生命周期里用固定的 helloWorld 串 + useCache:false 预热词典引擎，'
            '不是用户查词，也没有结果呈现。',
    'lib/src/sync/hibiki_remote_api_handlers.dart':
        '互联对端 / 浏览器扩展经 HTTP 拉词的服务端 handler：结果序列化给**远端**渲染，'
            '本机屏幕上什么都没发生，出声等于对着空气念。',
    'lib/src/sync/yomitan_api_server.dart':
        'Yomitan 兼容 API 的服务端：同上，结果给外部客户端消费，本机不该出声。',
    'lib/src/sync/hibiki_remote_lookup_client.dart':
        '本机作为 client 向 host 查词的传输层封装，返回给上层表面渲染；'
            '朗读由那个表面负责，这里重复朗读会双读。',
    'lib/src/sync/hibiki_remote_lookup_service.dart':
        '上一条的抽象接口声明（HibikiRemoteLookupService），只有方法签名没有实现体，'
            '不产生任何结果也不呈现 UI，谈不上朗读。',
  };

  /// 收集 lib/ 下所有 `searchDictionary(` 的**调用**点（排除声明/重写本身）。
  Set<String> collectCallSiteFiles() {
    final Set<String> hits = <String>{};
    for (final FileSystemEntity e
        in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String rel = e.path.replaceAll('\\', '/');
      for (final String line in e.readAsStringSync().split('\n')) {
        final String t = line.trim();
        if (t.startsWith('//') || t.startsWith('///')) continue;
        if (!t.contains('searchDictionary(')) continue;
        // 方法声明/接口签名本身不算调用点。
        if (RegExp(r'Future<DictionarySearchResult\??>\s+searchDictionary\(')
            .hasMatch(t)) {
          continue;
        }
        hits.add(rel);
      }
    }
    return hits;
  }

  test('每个查词调用点都必须显式声明接不接自动朗读', () {
    final Set<String> found = collectCallSiteFiles();
    expect(found, isNotEmpty,
        reason: '一个 searchDictionary 调用点都没扫到——扫描逻辑失效了，'
            '这条守卫会变成永远绿的摆设，请修扫描而不是删断言');
    final Set<String> declared = <String>{
      ...wiredSurfaces.keys,
      ...exemptCallSites.keys,
    };
    final Set<String> undeclared = found.difference(declared);
    expect(undeclared, isEmpty,
        reason: '这些文件里有查词调用点，但没在 wiredSurfaces / exemptCallSites 任一表中'
            '声明：$undeclared\n'
            '新增查词表面时必须显式选一边——接朗读就接上并进 wiredSurfaces，'
            '不该接就进 exemptCallSites 并写清**为什么不该出声**（BUG-1210）。');
  });

  test('wiredSurfaces 里的文件必须真的接了朗读（名单不许过期）', () {
    for (final MapEntry<String, String> e in wiredSurfaces.entries) {
      final File f = File(e.key);
      expect(f.existsSync(), true,
          reason: 'wiredSurfaces 里的 ${e.key} 已不存在，请更新名单');
      // 剥注释：讲「这里为什么要朗读」的注释里必然写着这些符号名，
      // 连注释一起扫会让「实现删光、注释还在」照样绿。
      final String code = f
          .readAsStringSync()
          .split('\n')
          .where((String l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final bool wired = code.contains('autoReadFirstEntry(') ||
          code.contains('autoReadWord(') ||
          code.contains('_autoReadWord(') ||
          code.contains('autoRead:');
      expect(wired, true,
          reason: '${e.key} 在 wiredSurfaces 里声明为「已接朗读」，但剥掉注释后找不到任何'
              '朗读调用——要么朗读被删了（回归），要么该挪进 exemptCallSites 并说明理由。');
    }
  });

  test('豁免必须带具体理由，不能是只有文件名的橡皮图章', () {
    for (final MapEntry<String, String> e in exemptCallSites.entries) {
      expect(File(e.key).existsSync(), true,
          reason: 'exemptCallSites 里的 ${e.key} 已不存在，请清理名单');
      final String why = e.value.trim();
      expect(why.length, greaterThanOrEqualTo(20),
          reason: '${e.key} 的豁免理由太短（"$why"）——要说清为什么这里不该自动出声');
      for (final String placeholder in <String>[
        'TODO',
        'FIXME',
        'n/a',
        'N/A',
        '待补'
      ]) {
        expect(why.contains(placeholder), false,
            reason: '${e.key} 的豁免理由是占位符（含 "$placeholder"），等于没写');
      }
    }
  });
}
