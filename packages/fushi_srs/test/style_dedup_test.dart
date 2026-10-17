import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

String _css(String tag, [int repeat = 40]) => List<String>.generate(
  repeat,
  (int i) => '.$tag-$i{color:#${(i * 7919 % 0xffffff).toRadixString(16)};}',
).join('\n');

void main() {
  final String dictA = _css('jmdict');
  final String dictB = _css('daijirin');
  const String small = '.x{color:red}';

  String gloss(String css, String body) =>
      '<div class="yomitan-glossary"><ol><li>$body</li></ol><style>$css</style></div>';

  test('够大的无属性 <style> 换成引用行；展开逐字节还原', () {
    final String html =
        '${gloss(dictA, 'snow')}${gloss(dictB, 'yuki')}${gloss(dictA, 'again')}';
    final SrsStyleDedup d = srsDedupStyles(html);
    expect(d.changed, isTrue);
    expect(d.styles.keys.toSet(), <String>{
      srsStyleMediaName(dictA),
      srsStyleMediaName(dictB),
    });
    expect(d.html, isNot(contains('<style>')));
    expect(
      d.html,
      contains('<link rel="stylesheet" href="${srsStyleMediaName(dictA)}">'),
    );
    expect(srsStyleRefsIn(d.html), d.styles.keys.toSet());
    expect(srsExpandStyles(d.html, (String n) => d.styles[n]), html);
    // 幂等：引用表示再去重一次不变。
    expect(srsDedupStyles(d.html).changed, isFalse);
    expect(srsDedupStyles(d.html).html, d.html);
  });

  test('文件名只由内容决定，形状固定', () {
    final String n = srsStyleMediaName(dictA);
    expect(n, startsWith(kSrsStyleMediaPrefix));
    expect(srsIsStyleMediaName(n), isTrue);
    expect(srsIsStyleMediaName('_fushi_style_abc.css'), isFalse);
    expect(srsStyleMediaName(dictA), n);
    expect(srsStyleMediaName('$dictA '), isNot(n));
  });

  test('小样式、带属性的 <style>、<script> 里的文字都不动', () {
    final String html =
        '<style>$small</style>'
        '<style media="print">$dictA</style>'
        '<STYLE>$dictA</STYLE>'
        '<script>var s = "<style>$dictB</style>";</script>';
    final SrsStyleDedup d = srsDedupStyles(html);
    expect(d.changed, isFalse);
    expect(d.html, html);
  });

  test('畸形：没闭合 / 嵌套的块原样保留，往返仍逐字节一致', () {
    for (final String html in <String>[
      '<style>$dictA',
      '<style>a<style>$dictB</style>tail',
      '<style>$dictA</style><style>$dictA</style>',
      '前<style>$dictA</style>中<script>x</script><style>$dictB</style>後',
    ]) {
      final SrsStyleDedup d = srsDedupStyles(html);
      expect(
        srsExpandStyles(d.html, (String n) => d.styles[n]),
        html,
        reason: html.substring(0, 20),
      );
    }
  });

  test('展开：找不到文件时保留或删掉引用行', () {
    final SrsStyleDedup d = srsDedupStyles(gloss(dictA, 'x'));
    expect(srsExpandStyles(d.html, (_) => null), d.html);
    expect(
      srsExpandStyles(d.html, (_) => null, dropMissing: true),
      '<div class="yomitan-glossary"><ol><li>x</li></ol></div>',
    );
  });

  test('合并口径：内联样式与引用行同值，内容不同仍不同', () {
    final String raw = gloss(dictA, 'snow');
    final String linked = srsDedupStyles(raw).html;
    expect(srsSameFieldText(raw, linked), isTrue);
    expect(srsSameFieldText(linked, raw), isTrue);
    expect(srsSameFieldText(raw, gloss(dictB, 'snow')), isFalse);
    expect(srsSameFieldText(linked, gloss(dictA, 'rain')), isFalse);
    expect(srsSameFieldText('a', 'b'), isFalse);
  });

  test('修改记录：同一内容两种表示并发写下不算冲突，也算 no-op', () {
    final String raw = gloss(dictA, 'snow');
    final String linked = srsDedupStyles(raw).html;
    SrsFieldEdit edit(String writer, Object? value) => SrsFieldEdit(
      profileUid: 'p',
      entityKind: SrsEntityKind.note,
      entityId: 'n',
      fieldKey: SrsFieldKeys.noteField('g'),
      dot: SrsDot(writer, 1),
      ctx: SrsCausalContext.empty(),
      value: value,
      hlc: Hlc(1000, 0, writer),
      timeSource: SrsTimeSource.wall,
    );
    final SrsRegister same = srsResolveRegister('k', <SrsFieldEdit>[
      edit('a', raw),
      edit('b', linked),
    ]);
    expect(same.live, hasLength(2));
    expect(same.conflicted, isFalse);
    expect(same.visibleLosers, isEmpty);
    expect(srsEditIsNoop(same, raw), isTrue);
    expect(srsEditIsNoop(same, linked), isTrue);

    final SrsRegister diff = srsResolveRegister('k', <SrsFieldEdit>[
      edit('a', raw),
      edit('b', srsDedupStyles(gloss(dictA, 'rain')).html),
    ]);
    expect(diff.conflicted, isTrue);
  });
}
