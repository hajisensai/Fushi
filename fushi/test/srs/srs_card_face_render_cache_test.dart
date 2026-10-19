import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:material_ui/material_ui.dart';

/// 卡面渲染的 Dart 侧缓存：
/// - [SrsCardFaceDocumentInputs]：复习页换一张卡要重建卡面 4~5 次，输入没变（同一张卡、同一
///   主题 / 外观 / 字体链）时文档原样复用，任何一项变了才重算；
/// - [SrsCardFaceDocumentCache]：外壳 HTML 懒算一次；
/// - [srsWarmCardFace]：预取到的下一张在出题间隙把预处理算进记忆表，显示时全命中。
void main() {
  const SrsCardLabels labels = SrsCardLabels(
    allDefinitions: 'a',
    frequency: 'f',
    source: 's',
  );
  final ThemeData theme = ThemeData();
  final List<Map<String, dynamic>> fonts = <Map<String, dynamic>>[];

  SrsCardFace face({
    String id = 'c1',
    bool answer = false,
    String body = '<b>Q</b>',
    String css = '.card{}',
    bool autoplay = true,
  }) => SrsCardFace(
    cardId: id,
    showingAnswer: answer,
    bodyHtml: body,
    css: css,
    autoplayMedia: autoplay,
    languageCode: 'ja',
    // 每次重建都是新闭包：不参与比较。
    onBridgeKey: (_) {},
  );

  SrsCardFaceDocumentInputs inputs(
    SrsCardFace f, {
    ThemeData? t,
    SrsCardAppearance appearance = const SrsCardAppearance(),
    List<Map<String, dynamic>>? fontList,
    String? fontRoot,
  }) => SrsCardFaceDocumentInputs(
    face: f,
    theme: t ?? theme,
    appearance: appearance,
    labels: labels,
    fonts: fontList ?? fonts,
    fontRoot: fontRoot,
  );

  group('SrsCardFaceDocumentInputs', () {
    test('同一张卡的重建（新 SrsCardFace 实例、新回调）视为相同', () {
      expect(inputs(face()), inputs(face()));
    });

    test('翻面 / 换卡 / 正文 / 样式 / 主题 / 外观 / 字体链 / 字体目录任一变化都要重算', () {
      final SrsCardFaceDocumentInputs base = inputs(face());
      expect(inputs(face(answer: true)), isNot(base));
      expect(inputs(face(id: 'c2')), isNot(base));
      expect(inputs(face(body: '<b>Q2</b>')), isNot(base));
      expect(inputs(face(css: '.card{color:red}')), isNot(base));
      expect(
        inputs(face(), t: ThemeData(brightness: Brightness.dark)),
        isNot(base),
      );
      expect(
        inputs(face(), appearance: const SrsCardAppearance(designSkin: false)),
        isNot(base),
      );
      expect(
        inputs(face(), fontList: <Map<String, dynamic>>[]),
        isNot(base),
        reason: '字体链按引用比：provider 换链就是新列表',
      );
      expect(inputs(face(), fontRoot: '/fonts'), isNot(base));
      expect(
        inputs(face(autoplay: false)),
        isNot(base),
        reason: '复习中关掉牌组自动播放要立即重下发，不能命中旧文档（BUG-3539）',
      );
    });

    test('缓存的外壳 HTML 与文档的一致（懒算一次）', () {
      final SrsCardFaceDocument doc = srsCardFaceDocumentFor(
        face(),
        theme: theme,
        appearance: const SrsCardAppearance(),
        labels: labels,
        mediaUrlPrefix: srsCardMediaUrlPrefix,
        themedScrollbar: false,
        fontUrl: (String p) => p,
      );
      final SrsCardFaceDocumentCache cache = SrsCardFaceDocumentCache(
        inputs(face()),
        doc,
      );
      expect(cache.shellHtml, doc.shellHtml);
      expect(identical(cache.shellHtml, cache.shellHtml), isTrue);
    });
  });

  test('srsWarmCardFace：预热不改结果，显示时同一份预处理（记忆表）', () {
    const String body =
        '<div>warm-unique-body</div><style>.d{color:red}</style><img src="a.png">';
    srsWarmCardFace(css: '.card{}', bodies: <String>[body]);
    final ({String body, List<String> styles}) first = srsPrepareCardBody(
      body,
      srsCardMediaUrlPrefix,
    );
    final ({String body, List<String> styles}) second = srsPrepareCardBody(
      body,
      srsCardMediaUrlPrefix,
    );
    expect(identical(first.styles, second.styles), isTrue);
    expect(first.styles, <String>['.d{color:red}']);
    expect(first.body, contains(srsCardMediaUrlPrefix));
    expect(first.body, isNot(contains('<style>')));
  });
}
