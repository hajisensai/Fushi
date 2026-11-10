// 源码守卫：复习卡面「这张卡用哪套渲染器」只在 lib/src/srs/srs_card_surface.dart 判一次
// （srsCardSurfaceOf）。BUG-3732 / BUG-3706 / BUG-3707 / BUG-4059 都是这条判据在复习页、浏览预览、
// 编辑预览、外观页各写一份、改一处漏一处造成的。
//
// 咬住三件事：
// 1. 底层探测（区块原生画不画得了、两面在不在原生 HTML 子集里、引擎区块布局判据、释义区在不在）
//    只在判据文件（及各自定义处）里调用；
// 2. 收口前的分站判据函数名不得再出现；
// 3. 建混合 / 原生 HTML 卡面视图的文件必须是拿判据结果建的（引用对应的结果类型）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _surface = 'lib/src/srs/srs_card_surface.dart';

/// 探测调用 → 允许出现的文件（判据文件 + 定义 / 与选渲染器无关的既有用处）。
final Map<RegExp, Set<String>> _probes = <RegExp, Set<String>>{
  RegExp(r'\bsrsFushiCardItemsNative\('): <String>{
    _surface,
    'lib/src/srs/srs_fushi_card_items.dart', // 定义处
  },
  RegExp(r'\bsrsHtmlCardOf\('): <String>{
    _surface,
    'lib/src/srs/srs_html_card.dart', // 定义处
  },
  RegExp(r'\bsrsHtmlCardProbe\('): <String>{
    'lib/src/srs/srs_html_card.dart', // 定义处（srsHtmlCardOf 是它的包装）
  },
  RegExp(r'\bsrsFushiCardNative\('): <String>{_surface},
  RegExp(r'fushiCardDefinitions\s*[!=]=\s*null'): <String>{
    _surface,
    // 远程库收集释义区引用的媒体文件名，不选渲染器。
    'lib/src/srs/srs_remote_store_client.dart',
  },
};

/// 收口前的分站判据：不许再长回来。
final List<RegExp> _retired = <RegExp>[
  RegExp(r'\bsrsNativeHtmlCardFor\b'),
  RegExp(r'\bsrsFushiCardRenderedNative\b'),
  RegExp(r'\bsrsNotePreviewNativeFushiCard\b'),
];

/// 建视图 → 同文件必须引用的判据结果类型。
final Map<RegExp, ({String defFile, String needs})> _views =
    <RegExp, ({String defFile, String needs})>{
      RegExp(r'\bSrsFushiCardView\('): (
        defFile: 'lib/src/pages/implementations/srs/srs_fushi_card_view.dart',
        needs: 'SrsFushiHybridSurface',
      ),
      RegExp(r'\bSrsHtmlCardView\('): (
        defFile: 'lib/src/pages/implementations/srs/srs_html_card_view.dart',
        needs: 'SrsHtmlNativeSurface',
      ),
    };

/// 去掉整行注释（文档注释里会以 `[name]` 提到这些函数）。
String _code(String src) => src
    .split('\n')
    .where((String l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  final Map<String, String> sources = <String, String>{
    for (final FileSystemEntity f in Directory('lib').listSync(recursive: true))
      if (f is File && f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
        f.path.replaceAll(r'\', '/'): _code(f.readAsStringSync()),
  };

  test('扫到了源码与判据文件', () {
    expect(sources.length, greaterThan(500));
    expect(sources.containsKey(_surface), isTrue);
    final String surface = sources[_surface]!;
    for (final String name in <String>[
      'srsFushiCardItemsNative(',
      'srsHtmlCardOf(',
      'srsFushiCardNative(',
      'SrsCardSurface srsCardSurfaceOf(',
    ]) {
      expect(surface, contains(name), reason: '判据文件里应当调用 / 定义 $name');
    }
  });

  test('底层探测只在判据文件里调用', () {
    final List<String> offenders = <String>[];
    _probes.forEach((RegExp re, Set<String> allowed) {
      sources.forEach((String path, String src) {
        if (!allowed.contains(path) && re.hasMatch(src)) {
          offenders.add('$path: ${re.pattern}');
        }
      });
    });
    expect(
      offenders,
      isEmpty,
      reason: '选渲染器一律调 srsCardSurfaceOf / srsCardSurfaceOfRendered，不要另写一份判据',
    );
  });

  test('收口前的分站判据不得再出现', () {
    final List<String> offenders = <String>[
      for (final MapEntry<String, String> e in sources.entries)
        for (final RegExp re in _retired)
          if (re.hasMatch(e.value)) '${e.key}: ${re.pattern}',
    ];
    expect(offenders, isEmpty);
  });

  test('建混合 / 原生 HTML 卡面视图的地方都拿判据结果建', () {
    final List<String> offenders = <String>[];
    _views.forEach((RegExp re, ({String defFile, String needs}) v) {
      sources.forEach((String path, String src) {
        if (path == v.defFile || !re.hasMatch(src)) return;
        if (!src.contains(v.needs)) offenders.add('$path 缺 ${v.needs}');
      });
    });
    expect(offenders, isEmpty);
  });
}
