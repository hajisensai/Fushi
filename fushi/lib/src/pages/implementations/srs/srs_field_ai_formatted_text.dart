/// 字段 AI 建议的预览：把清洗过的回复 HTML（`aiSrsFieldSanitizeHtml` 的白名单：b / i / u / br /
/// ul / ol / li / ruby / rt / rp / div / p / span / mark / sub / sup，全都不带属性）画成带格式的
/// Flutter 文字，用户在点「替换 / 追加」之前看到的就是卡上会出现的强调、换行、列表和注音。
///
/// 不用卡面的原生 HTML 渲染器（`SrsHtmlFragmentView`）：它连着卡面外观 / 媒体库的 Riverpod
/// 状态，还要整套 CSS 布局；这里的输入是白名单内、无属性的规范 HTML，一层行内样式就够。
/// 白名单之外的元素（理论上不会出现）按「拆壳留文字」画，不丢字。
///
/// 与设计系统无关：只决定字重 / 斜体 / 下划线 / 高亮 / 换行，颜色与字号来自调用方的 [TextStyle]。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;
import 'package:material_ui/material_ui.dart';

/// [html] 画成的行内文字段（纯函数，单测直接调）。
///
/// - 空白按 HTML 规则折叠（连续空白 = 一个空格，行首空格去掉），`<br>` 换行；
/// - `div` / `p` / `li` 各自成行，列表项前缀「• 」/「1. 」，嵌套列表按层缩进；
/// - `ruby`：读音（[rubyStyle]）画在基字上方（[WidgetSpan]），`rp` 不画。
InlineSpan srsFieldAiFormattedSpan(
  String html, {
  required TextStyle style,
  required TextStyle rubyStyle,
  required Color markColor,
}) {
  final _SpanWriter w = _SpanWriter(rubyStyle: rubyStyle, markColor: markColor);
  w.nodes(parseFragment(html).nodes, style);
  return TextSpan(style: style, children: w.out);
}

/// 一段建议画成的 [Text]（[key] 给在这个 Text 上，测试按 key 取它的文字段）。
Text srsFieldAiFormattedText(
  BuildContext context,
  String html, {
  required TextStyle style,
  Key? key,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return Text.rich(
    srsFieldAiFormattedSpan(
      html,
      style: style,
      rubyStyle: _scaled(
        style,
        0.55,
      ).copyWith(height: 1.1, color: scheme.onSurfaceVariant),
      markColor: scheme.tertiaryContainer,
    ),
    key: key,
  );
}

final RegExp _space = RegExp(r'[ \t\r\n\f]+');

class _SpanWriter {
  _SpanWriter({required this.rubyStyle, required this.markColor});

  final TextStyle rubyStyle;
  final Color markColor;
  final List<InlineSpan> out = <InlineSpan>[];

  /// 当前输出在行首（还没写字 / 刚换行）。
  bool _lineStart = true;

  /// 块边界：下一段文字之前要先换行（块之间只换一次，不叠空行）。
  bool _pendingBreak = false;

  /// 打开着的列表：每层是否有序、已写到第几项。
  final List<({bool ordered, int count})> _lists =
      <({bool ordered, int count})>[];

  void _block() {
    if (!_lineStart) _pendingBreak = true;
  }

  void _flushBreak(TextStyle style) {
    if (!_pendingBreak) return;
    _pendingBreak = false;
    out.add(TextSpan(text: '\n', style: style));
    _lineStart = true;
  }

  void _write(String text, TextStyle style) {
    if (text.isEmpty) return;
    _flushBreak(style);
    out.add(TextSpan(text: text, style: style));
    _lineStart = text.endsWith('\n');
  }

  void _text(String raw, TextStyle style) {
    String s = raw.replaceAll(_space, ' ');
    if (_lineStart || _pendingBreak) s = s.trimLeft();
    _write(s, style);
  }

  void nodes(List<dom.Node> nodes, TextStyle style) {
    for (final dom.Node n in nodes) {
      if (n is dom.Text) {
        _text(n.data, style);
      } else if (n is dom.Element) {
        _element(n, style);
      }
    }
  }

  void _element(dom.Element e, TextStyle style) {
    final String tag = (e.localName ?? '').toLowerCase();
    switch (tag) {
      case 'br':
        _pendingBreak = false;
        out.add(TextSpan(text: '\n', style: style));
        _lineStart = true;
      case 'b':
        nodes(e.nodes, style.copyWith(fontWeight: FontWeight.w700));
      case 'i':
        nodes(e.nodes, style.copyWith(fontStyle: FontStyle.italic));
      case 'u':
        nodes(
          e.nodes,
          style.copyWith(
            decoration: TextDecoration.combine(<TextDecoration>[
              ?style.decoration,
              TextDecoration.underline,
            ]),
          ),
        );
      case 'mark':
        nodes(e.nodes, style.copyWith(backgroundColor: markColor));
      case 'sub' || 'sup':
        nodes(
          e.nodes,
          _scaled(style, 0.75).copyWith(
            fontFeatures: <FontFeature>[
              ...?style.fontFeatures,
              tag == 'sub'
                  ? const FontFeature.subscripts()
                  : const FontFeature.superscripts(),
            ],
          ),
        );
      case 'div' || 'p':
        _block();
        nodes(e.nodes, style);
        _block();
      case 'ul' || 'ol':
        _block();
        _lists.add((ordered: tag == 'ol', count: 0));
        nodes(e.nodes, style);
        _lists.removeLast();
        _block();
      case 'li':
        _block();
        final String prefix;
        if (_lists.isEmpty) {
          prefix = '• ';
        } else {
          final ({bool ordered, int count}) top = _lists.removeLast();
          final int n = top.count + 1;
          _lists.add((ordered: top.ordered, count: n));
          prefix =
              '${'    ' * (_lists.length - 1)}${top.ordered ? '$n. ' : '• '}';
        }
        _write(prefix, style);
        nodes(e.nodes, style);
        _block();
      case 'ruby':
        _ruby(e, style);
      case 'rp':
        break; // 注音的括号：给不支持 ruby 的阅读器看的，原生画注音时不画。
      default: // span / rt（落单）/ 白名单外：拆壳留文字。
        nodes(e.nodes, style);
    }
  }

  void _ruby(dom.Element e, TextStyle style) {
    final StringBuffer base = StringBuffer();
    final StringBuffer reading = StringBuffer();
    void collect(List<dom.Node> nodes, StringBuffer into) {
      for (final dom.Node n in nodes) {
        if (n is dom.Text) {
          into.write(n.data.replaceAll(_space, ' '));
        } else if (n is dom.Element) {
          final String tag = (n.localName ?? '').toLowerCase();
          if (tag == 'rp') continue;
          collect(n.nodes, tag == 'rt' ? reading : into);
        }
      }
    }

    collect(e.nodes, base);
    final String b = base.toString().trim();
    final String r = reading.toString().trim();
    if (r.isEmpty) {
      _text(b, style);
      return;
    }
    _flushBreak(style);
    out.add(
      WidgetSpan(
        // 底对齐：Column 的基线是读音那一行，按基线对齐会让基字掉到行下面。
        alignment: PlaceholderAlignment.bottom,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(r, style: rubyStyle, maxLines: 1),
            Text(b, style: style),
          ],
        ),
      ),
    );
    _lineStart = false;
  }
}

/// 按字号比例缩放（注音 / 上下标相对正文字号，不另立绝对字号）；没有字号的样式原样
/// 交回，由继承的 DefaultTextStyle 决定。
TextStyle _scaled(TextStyle style, double factor) =>
    style.fontSize == null ? style : style.apply(fontSizeFactor: factor);
