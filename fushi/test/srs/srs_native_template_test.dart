// 模板级「原生渲染」标记：标记写进 / 读出正面模板（与可视化布局注释共存、往返无损），以及
// 标了标记的卡一律原生——画不了的块就地换成提示，不回退整面 WebView。
import 'package:test/test.dart';

import 'package:fushi/src/srs/srs_html_card.dart';
import 'package:fushi/src/srs/srs_native_template.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';

const SrsVisualCompileContext _ctx = SrsVisualCompileContext(
  fieldNameById: <String, String>{'f1': 'Front', 'f2': 'Back'},
);

const List<SrsVisualBlock> _blocks = <SrsVisualBlock>[
  SrsVisualBlock(id: 'b1', kind: SrsVisualBlockKind.field, fieldId: 'f1'),
  SrsVisualBlock(id: 'b2', kind: SrsVisualBlockKind.field, fieldId: 'f2'),
];

String _notice(String reason) => 'NATIVE-NO[$reason]';

List<SrsHtmlNode> _flat(SrsHtmlBlock b) => <SrsHtmlNode>[
  b,
  for (final SrsHtmlNode c in b.children)
    if (c is SrsHtmlBlock) ..._flat(c) else c,
];

/// 一面（浅色主题）排出来的全部文字。
String _textOf(SrsHtmlCardFace face) {
  final StringBuffer out = StringBuffer();
  void inlines(List<SrsHtmlInline> runs) {
    for (final SrsHtmlInline r in runs) {
      switch (r) {
        case SrsHtmlTextRun(:final String text):
          out.write(text);
        case SrsHtmlRubyRun(:final String base):
          out.write(base);
        case SrsHtmlBoxRun(:final SrsHtmlBlock box):
          for (final SrsHtmlNode n in _flat(box)) {
            if (n is SrsHtmlFlow) inlines(n.inlines);
          }
        default:
          break;
      }
    }
  }

  for (final SrsHtmlNode n in _flat(
    face.layout(dark: false, foreground: 0xFF000000),
  )) {
    if (n is SrsHtmlFlow) inlines(n.inlines);
  }
  return out.toString();
}

void main() {
  group('标记读写', () {
    test('代码模板：打上 / 去掉标记往返无损，打两次与打一次相同', () {
      const String src = '{{Front}}';
      final String on = srsWithTemplateNative(src, true);
      expect(on, '$kSrsNativeTemplateMarker\n$src');
      expect(srsTemplateIsNative(on), isTrue);
      expect(srsWithTemplateNative(on, true), on);
      expect(srsStripTemplateNative(on), src);
      expect(srsWithTemplateNative(on, false), src);
      expect(srsTemplateIsNative(src), isFalse);
    });

    test('标记只认模板开头：字段内容里出现同样的注释不算', () {
      expect(srsTemplateIsNative('{{Front}}\n<!--fushi-native-->'), isFalse);
      expect(srsTemplateIsNative('<div><!--fushi-native--></div>'), isFalse);
    });

    test('可视化模板：标记放在布局注释之后，布局仍读得回、不算手改，去掉后逐字还原', () {
      final String src = srsCompileVisualSide(_blocks, _ctx);
      final String on = srsWithTemplateNative(src, true);
      expect(on, startsWith(kSrsVisualMarkerPrefix));
      expect(srsTemplateIsNative(on), isTrue);
      expect(srsParseVisualMarker(on), isNotNull);
      final SrsVisualSideState state = srsReadVisualSide(on, _ctx);
      expect(state.isVisual, isTrue);
      expect(state.edited, isFalse, reason: '原生标记是元数据，不是手改代码');
      expect(srsStripTemplateNative(on), src);
      expect(srsWithTemplateNative(on, true), on);
    });

    test('删字段重编可视化正面时保住原生标记', () {
      final String on = srsWithTemplateNative(
        srsCompileVisualSide(_blocks, _ctx),
        true,
      );
      final String? dropped = srsVisualDropField(on, 'f2', _ctx);
      expect(dropped, isNotNull);
      expect(srsTemplateIsNative(dropped!), isTrue);
      expect(dropped, isNot(contains('{{Back}}')));
      expect(srsReadVisualSide(dropped, _ctx).edited, isFalse);
    });
  });

  group('强制原生', () {
    const String table = '<table><tr><td>表格内容</td></tr></table>';

    test('没标记的卡：画不了照旧整张回退（判据不变）', () {
      const String q = '<div>猫</div>$table';
      expect(srsTemplateIsNative(q), isFalse);
      expect(srsHtmlCardOf(question: q, answer: q, css: ''), isNull);
    });

    test('标了标记：画不了的块换成提示，其余块照样原生画', () {
      const String q = '$kSrsNativeTemplateMarker\n<div>猫</div>\n$table';
      const String a = '$q\n<div>cat</div>';
      expect(srsTemplateIsNative(q), isTrue);
      final SrsForcedNativeCard forced = srsForcedNativeHtmlCard(
        question: q,
        answer: a,
        css: '',
        notice: _notice,
      );
      expect(forced.reasons, <String>['html: <table>']);
      final String front = _textOf(forced.card.question);
      expect(front, contains('猫'));
      expect(front, contains('NATIVE-NO[html: <table>]'));
      expect(front, isNot(contains('表格内容')));
      final String back = _textOf(forced.card.answer);
      expect(back, contains('cat'));
      expect(back, contains('NATIVE-NO[html: <table>]'));
      // 暗色主题同样排得出来。
      forced.card.answer.layout(dark: true, foreground: 0xFFFFFFFF);
    });

    test('可视化容器往里展开一层：只换掉画不了的那一块', () {
      const String q =
          '$kSrsNativeTemplateMarker\n<div class="fushi-visual">\n'
          '<div class="fv-block">猫</div>\n<div class="fv-block">$table</div>\n'
          '<div class="fv-block">ねこ</div>\n</div>';
      final SrsForcedNativeCard forced = srsForcedNativeHtmlCard(
        question: q,
        answer: q,
        css: '',
        notice: _notice,
      );
      final String text = _textOf(forced.card.question);
      expect(text, contains('猫'));
      expect(text, contains('ねこ'));
      expect(text, contains('NATIVE-NO[html: <table>]'));
    });

    test('样式表画不了：两面不用它并在最前面提示，内容照样原生画', () {
      const String q = '$kSrsNativeTemplateMarker\n<div class="a">猫</div>';
      const String css = '@media (max-width: 400px) { .a { color: red; } }';
      final SrsForcedNativeCard forced = srsForcedNativeHtmlCard(
        question: q,
        answer: q,
        css: css,
        notice: _notice,
      );
      expect(forced.reasons, hasLength(1));
      expect(forced.reasons.single, startsWith('css:'));
      final String text = _textOf(forced.card.question);
      expect(text, startsWith('NATIVE-NO[css:'));
      expect(text, contains('猫'));
    });

    test('标了标记且两面画得全：原样画、没有提示', () {
      const String q = '$kSrsNativeTemplateMarker\n<div>猫</div>';
      final SrsForcedNativeCard forced = srsForcedNativeHtmlCard(
        question: q,
        answer: '$q<hr><div>cat</div>',
        css: '.card { text-align: center; }',
        notice: _notice,
      );
      expect(forced.reasons, isEmpty);
      expect(_textOf(forced.card.question), isNot(contains('NATIVE-NO')));
      expect(_textOf(forced.card.answer), contains('cat'));
    });
  });
}
