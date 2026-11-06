import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 查词弹窗打开期间给宿主正文 WebView 开静态硬件层（Android Hybrid Composition，
/// `PopupBodyStaticLayerGate`）——钉住唯一收口点与每个宿主的接线。
///
/// fork 的 Android WebView 默认不挂硬件层（滚动时省掉每帧重画整屏离屏层），代价是
/// 正文静止、上面的查词弹窗 WebView 在动时正文每帧都要重画（120Hz 平板弹窗滚动
/// 80 → 61 fps）。收口点是 `DictionaryPopupController`：栈一变就把「弹窗是否在屏上」
/// 交给闸门；宿主只提供正文 viewId（`popupBodyWebViewId`）并在 `onWebViewCreated`
/// 通知正文换了。漏接一个宿主，那一页的查词弹窗就静默退回慢路径，没有任何报错。
///
/// 下面按「弹窗宿主」目录枚举：新增一个宿主必须在 [_wired] 或 [_exempt] 里表态。
void main() {
  String read(String path) {
    final File f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path missing');
    return maskComments(f.readAsStringSync());
  }

  test('DictionaryPopupController 是唯一收口：监听自身变化并在 dispose 关层', () {
    final String src = read(
      'lib/src/pages/implementations/dictionary_popup_controller.dart',
    );
    expect(src, contains('addListener(_syncBodyStaticLayer)'));
    expect(
      src,
      contains(
        'bodyStaticLayer.popupOpenChanged(hasVisiblePopup || isSearchingUi)',
      ),
    );
    expect(src, contains('bodyStaticLayer.dispose()'));
    expect(src, contains('platformWebViewStaticLayerSetter()'));

    final String gate = read(
      'lib/src/pages/implementations/popup_body_static_layer.dart',
    );
    expect(
      gate,
      contains('isAndroidPlatform ? AndroidWebViewStaticLayer.set : null'),
      reason: '平台判据走 platform_utils，只在 Android 调 fork 接口',
    );
    // 别处不许绕过闸门直接调 fork 接口（会和闸门的记账打架）。
    for (final File f in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (f.path
          .replaceAll(r'\', '/')
          .endsWith('popup_body_static_layer.dart')) {
        continue;
      }
      expect(
        maskComments(
          f.readAsStringSync(),
        ).contains('AndroidWebViewStaticLayer'),
        isFalse,
        reason: '${f.path} calls AndroidWebViewStaticLayer directly',
      );
    }
  });

  test('BaseSourcePage 把 popupBodyWebViewId 接到闸门', () {
    final String src = read('lib/src/pages/base_source_page.dart');
    expect(
      src,
      contains('_popup.bodyStaticLayer.resolveBody = () => popupBodyWebViewId'),
    );
    expect(src, contains('_popup.bodyStaticLayer.bodyChanged()'));
  });

  test('每个弹窗宿主都表态：WebView 正文的已接线，其余写明理由', () {
    final RegExp host = RegExp(
      r'extends BaseSourcePageState<|with\s[^{]*\bDictionaryPageMixin\b',
    );
    final Set<String> found = <String>{};
    for (final File f in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final String path = f.path.replaceAll(r'\', '/');
      if (host.hasMatch(maskComments(f.readAsStringSync()))) found.add(path);
    }
    found.remove('lib/src/pages/base_source_page.dart');
    expect(found, <String>{
      ..._wired.keys,
      ..._exempt.keys,
    }, reason: '新的查词弹窗宿主：WebView 正文就接 popupBodyWebViewId，否则进 _exempt');

    for (final MapEntry<String, List<String>> e in _wired.entries) {
      final String src = <String>[
        e.key,
        ..._wiredParts[e.key] ?? <String>[],
      ].map(read).join('\n');
      for (final String needle in e.value) {
        expect(src, contains(needle), reason: '${e.key} lost `$needle`');
      }
    }
  });

  test('浏览器标签页 / 复习卡面作为发起表面提供正文 WebView', () {
    final String host = read(
      'lib/src/pages/implementations/srs/srs_card_lookup.dart',
    );
    expect(host, contains('_popup.bodyStaticLayer.resolveBody'));
    expect(host, contains('_host?._popup.bodyStaticLayer.bodyChanged()'));
    expect(host, contains('case final PopupBodyWebViewProvider provider'));

    for (final String path in <String>[
      'lib/src/web_browser/tab_view/web_browser_tab_view.dart',
      'lib/src/pages/implementations/srs/srs_card_face.dart',
    ]) {
      final String src = read(path);
      expect(
        src,
        contains('implements SrsCardLookupSurface, PopupBodyWebViewProvider'),
        reason: path,
      );
      expect(src, contains('popupBodyWebViewId => _controller?.getViewId()'));
      expect(src, contains('_lookup?.bodyWebViewChanged(this)'), reason: path);
    }
  });
}

/// 正文是 WebView 的宿主 → 必须出现的接线片段。
const Map<String, List<String>> _wired = <String, List<String>>{
  'lib/src/pages/implementations/reader_fushi_page.dart': <String>[
    'Object? get popupBodyWebViewId => _lyricsMode',
    '_controller = controller;\n        notifyPopupBodyWebViewChanged();',
    '_lyricsWebViewController = controller;\n        notifyPopupBodyWebViewChanged();',
    '_lyricsMode = true);\n        notifyPopupBodyWebViewChanged();',
    '_lyricsMode = false);\n        notifyPopupBodyWebViewChanged();',
  ],
  'lib/src/media/manga/reader/manga_fushi_page.dart': <String>[
    'Object? get popupBodyWebViewId => _controller?.getViewId()',
    '_controller = controller;\n        notifyPopupBodyWebViewChanged();',
  ],
  'lib/src/pages/implementations/web_video_fushi_page.dart': <String>[
    'implements PopupBodyWebViewProvider',
    'Object? get popupBodyWebViewId => _web?.getViewId()',
    '_popup.bodyStaticLayer.resolveBody = () => popupBodyWebViewId',
    '_popup.bodyStaticLayer.bodyChanged()',
  ],
  // 浏览器标签页 / 复习卡面经发起表面提供正文（见下一条测试）。
  'lib/src/pages/implementations/srs/srs_card_lookup.dart': <String>[
    '_popup.bodyStaticLayer.resolveBody',
  ],
};

/// 阅读器的 WebView 在 part 文件里建。
const Map<String, List<String>> _wiredParts = <String, List<String>>{
  'lib/src/pages/implementations/reader_fushi_page.dart': <String>[
    'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
  ],
};

/// 正文不是 WebView（或根本没有正文）的宿主：不开层。
const Map<String, String> _exempt = <String, String>{
  'lib/src/pages/implementations/reader_pdf_page.dart': 'pdfrx 渲染，不是 WebView',
  'lib/src/pages/implementations/music/music_lyrics_page.dart': 'Flutter 歌词列表',
  'lib/src/pages/implementations/video_fushi_page.dart': 'mpv 视频纹理',
  'lib/src/pages/implementations/video_remote_page.dart': 'mpv 视频纹理',
  'lib/src/pages/implementations/home_dictionary_page.dart': '首页查词，无正文',
  'lib/src/pages/implementations/popup_dictionary_page.dart': '独立查词窗，无正文',
  'lib/src/pages/implementations/texthooker_page.dart': 'Flutter 文本列表',
  'lib/src/media/audiobook/floating_lyric_lookup_host.dart': '悬浮歌词，Flutter 文本',
};
