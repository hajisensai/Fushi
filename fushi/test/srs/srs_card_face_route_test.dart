// 卡面路线的统一判据（反馈 O5YDP27Xko）：复习页、浏览预览、笔记 / 模板编辑预览、外观页预览
// 只经 srsCardFaceRoute 判「原生 Fushi / 原生 HTML / 整面 WebView（带原因）」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_card_face_route.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsRenderedCard;
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart';

Map<String, String> _fields([Map<String, String> extra = const {}]) =>
    <String, String>{
      for (final String f in FushiCardNoteType.fields) f: '',
      'Term': '免許',
      ...extra,
    };

SrsRenderedCard _fushi({
  List<FushiCardItem> back = const <FushiCardItem>[],
  SrsCardNativeFallback? fallback,
  bool native = true,
}) => SrsRenderedCard(
  question: '<div>q</div>',
  answer: '<div>a</div>',
  css: kFushiCardStylingCss,
  isEmpty: false,
  fields: _fields(),
  fushiCardDefinitions: native ? '<div>defs</div>' : null,
  fushiCardFront: native ? kFushiCardDefaultFrontItems : const [],
  fushiCardBack: native
      ? <FushiCardItem>[...kFushiCardDefaultBackItems, ...back]
      : const [],
  nativeFallback: fallback,
);

void main() {
  group('srsCardFaceRoute', () {
    test('引擎认得出布局、区块画得全：原生 Fushi 卡面', () {
      expect(
        srsCardFaceRoute(_fushi(), fushiCard: true),
        isA<SrsCardFaceFushiNative>(),
      );
    });

    test('HTML 区块画不了：整面 WebView，原因 block + 子集原因', () {
      final SrsCardFaceRoute r = srsCardFaceRoute(
        _fushi(
          back: <FushiCardItem>[
            const FushiCardHtmlItem('<script>alert(1)</script>'),
          ],
        ),
        fushiCard: true,
        languageCode: 'ja',
      );
      expect(r, isA<SrsCardFaceWeb>());
      final SrsCardNativeFallback f = (r as SrsCardFaceWeb).fallback;
      expect(f.code, SrsCardNativeFallbackCode.block);
      expect(f.detail, isNotEmpty);
    });

    test('引擎没给布局：带引擎原因；远程老主机没带原因时 remoteUnknown', () {
      const SrsCardNativeFallback css = SrsCardNativeFallback(
        SrsCardNativeFallbackCode.cssModified,
      );
      final SrsCardFaceRoute r = srsCardFaceRoute(
        _fushi(native: false, fallback: css),
        fushiCard: true,
      );
      expect((r as SrsCardFaceWeb).fallback, css);
      final SrsCardFaceRoute old = srsCardFaceRoute(
        _fushi(native: false),
        fushiCard: true,
      );
      expect(
        (old as SrsCardFaceWeb).fallback.code,
        SrsCardNativeFallbackCode.remoteUnknown,
      );
    });

    test('非 Fushi 卡片：子集内原生 HTML，子集外整面 WebView（html + 原因）', () {
      const SrsRenderedCard plain = SrsRenderedCard(
        question: '<div>front</div>',
        answer: '<div>back</div>',
        css: '.card { color: black; }',
        isEmpty: false,
        nativeFallback: SrsCardNativeFallback(
          SrsCardNativeFallbackCode.notBuiltin,
        ),
      );
      expect(
        srsCardFaceRoute(plain, fushiCard: false),
        isA<SrsCardFaceHtmlNative>(),
      );
      const SrsRenderedCard scripted = SrsRenderedCard(
        question: '<div>front</div><script>x()</script>',
        answer: '<div>back</div>',
        css: '',
        isEmpty: false,
      );
      final SrsCardFaceRoute r = srsCardFaceRoute(scripted, fushiCard: false);
      expect(
        (r as SrsCardFaceWeb).fallback.code,
        SrsCardNativeFallbackCode.html,
      );
    });
  });

  // 守卫：卡面路线只在 srs_card_face_route.dart 判一次。页面里再各拼一份原生判据（以前的
  // srsFushiCardRenderedNative / srsNativeHtmlCardFor），四处预览与复习页就会各走各的。
  test('页面不得绕过 srsCardFaceRoute 直接判原生卡面', () {
    final RegExp banned = RegExp(
      r'\b(srsFushiCardRenderedNative|srsNativeHtmlCardFor|'
      r'srsFushiCardItemsFallback|srsHtmlCardProbe|srsHtmlCardOf)\s*\(',
    );
    final Directory pages = Directory('lib/src/pages/implementations/srs');
    final List<String> offenders = <String>[
      for (final FileSystemEntity f in pages.listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            banned.hasMatch(f.readAsStringSync()))
          f.path,
    ];
    expect(offenders, isEmpty);
    for (final String name in <String>[
      'srs_review_page.dart',
      'srs_browse_preview.dart',
      'srs_note_preview.dart',
      'srs_card_appearance_page.dart',
    ]) {
      expect(
        File('${pages.path}/$name').readAsStringSync(),
        contains('srsCardFaceRoute('),
        reason: '$name 经统一判据选卡面',
      );
    }
  });
}
