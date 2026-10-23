/// 笔记编辑页的富文本输入：一个 [TextEditingController]，额外为每个字符记一份行内格式
/// （[SrsRichFormat]，含高亮，见 srs_rich_format.dart），按样式画 [TextSpan]，并序列化回 Anki 写法的 HTML。
///
/// 为什么不用 WebView contenteditable：编辑页一屏十来个字段，每个字段一个 WebView 太重
/// （桌面 WebView2 / 移动端平台视图都是独立进程或纹理），且焦点 / 输入法 / 快捷键要跨
/// 平台视图边界桥接；这里的格式只有加粗 / 斜体 / 下划线 / 颜色 / 高亮 / 注音，原生 [EditableText] 足够，
/// 输入法、撤销、选择、手柄焦点全部沿用 app 现有的文本框行为。
///
/// **注音**：输入框里不画上方读音（[EditableText] 的选区 / 光标按字形排，行内塞读音会错位），
/// 带注音的字只加点状下划线；真正的注音效果由编辑器在输入框上方另画一行（见
/// [rubyGroups]）。在一组注音中间打字，新字归进这一组；在组的两头打字不带注音。
///
/// **往返不变**：没改过（文字与样式都与载入时相同）时 [html] 原样返回载入时的字符串，
/// 不经序列化——`<strong>` 不会被改写成 `<b>`、实体不会被重新转义。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_field_markup.dart' show SrsRichAttr;
import 'package:fushi/src/srs/srs_rich_format.dart';

class SrsRichTextController extends TextEditingController {
  SrsRichTextController._(this._original, SrsRichFormatDoc doc)
    : _styles = List<SrsRichFormat>.of(doc.formats),
      _initialText = doc.text,
      _initialStyles = List<SrsRichFormat>.unmodifiable(doc.formats),
      super(text: doc.text);

  /// 从字段 HTML 建；不在子集里（见 [srsParseRichFormatHtml]）返回 null。
  static SrsRichTextController? tryParse(String html) {
    final SrsRichFormatDoc? doc = srsParseRichFormatHtml(html);
    return doc == null ? null : SrsRichTextController._(html, doc);
  }

  final String _original;
  final String _initialText;
  final List<SrsRichFormat> _initialStyles;
  List<SrsRichFormat> _styles;

  /// 折叠光标下「接下来输入的字」的样式（点了加粗再打字）；移动光标即作废。
  SrsRichFormat? _pending;

  /// 逐字符样式（只读视图）。
  List<SrsRichFormat> get styles => List<SrsRichFormat>.unmodifiable(_styles);

  /// 和载入时相比改过没有。
  bool get dirty =>
      text != _initialText || !srsSameFormats(_styles, _initialStyles);

  /// 字段值：没改过 = 原样的载入值；改过 = 序列化。
  String get html => dirty ? srsRichFormatToHtml(text, _styles) : _original;

  SrsRichFormat _styleBefore(int offset) {
    if (_styles.isEmpty) return SrsRichFormat.plain;
    if (offset > 0) return _styles[math.min(offset, _styles.length) - 1];
    return _styles.first;
  }

  @override
  set value(TextEditingValue newValue) {
    final String old = text;
    final String next = newValue.text;
    if (old != next) {
      // 用公共前后缀找出被替换的一段；光标位置约束插入段的落点（连打同一个字时不歧义）。
      final int caret = newValue.selection.isValid
          ? math.min(newValue.selection.end, next.length)
          : next.length;
      int prefix = 0;
      final int maxPrefix = math.min(math.min(old.length, next.length), caret);
      while (prefix < maxPrefix &&
          old.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
        prefix++;
      }
      int suffix = 0;
      final int maxSuffix = math.min(
        math.min(old.length, next.length) - prefix,
        next.length - math.max(caret, prefix),
      );
      while (suffix < maxSuffix &&
          old.codeUnitAt(old.length - 1 - suffix) ==
              next.codeUnitAt(next.length - 1 - suffix)) {
        suffix++;
      }
      final int inserted = next.length - prefix - suffix;
      SrsRichFormat style = _pending ?? _styleBefore(prefix);
      final SrsRuby? ruby = style.ruby;
      if (ruby != null) {
        final int after = old.length - suffix;
        final bool inside =
            prefix > 0 &&
            after < old.length &&
            _styles[prefix - 1].ruby == ruby &&
            _styles[after].ruby == ruby &&
            !next.substring(prefix, prefix + inserted).contains('\n');
        if (!inside) style = style.withRuby(null);
      }
      _styles = <SrsRichFormat>[
        ..._styles.sublist(0, prefix),
        ...List<SrsRichFormat>.filled(inserted, style),
        ..._styles.sublist(old.length - suffix),
      ];
      _pending = null;
    } else if (newValue.selection != selection) {
      _pending = null;
    }
    super.value = newValue;
  }

  /// 当前选区（或光标处）是否带 [attr]：选区内每个字都带才算。
  bool isActive(SrsRichAttr attr) {
    final TextSelection sel = selection;
    if (!sel.isValid || sel.isCollapsed) {
      return (_pending ?? _styleBefore(sel.isValid ? sel.start : text.length))
          .has(attr);
    }
    for (int i = sel.start; i < sel.end; i++) {
      if (!_styles[i].has(attr)) return false;
    }
    return true;
  }

  /// 当前选区（或光标处）的颜色；选区里颜色不一致时 null。
  int? get activeColor {
    final TextSelection sel = selection;
    if (!sel.isValid || sel.isCollapsed) {
      return (_pending ?? _styleBefore(sel.isValid ? sel.start : text.length))
          .color;
    }
    final int? first = _styles[sel.start].color;
    for (int i = sel.start; i < sel.end; i++) {
      if (_styles[i].color != first) return null;
    }
    return first;
  }

  void _restyle(SrsRichFormat Function(SrsRichFormat s) change) {
    final TextSelection sel = selection;
    if (!sel.isValid || sel.isCollapsed) {
      _pending = change(
        _pending ?? _styleBefore(sel.isValid ? sel.start : text.length),
      );
    } else {
      for (int i = sel.start; i < sel.end; i++) {
        _styles[i] = change(_styles[i]);
      }
    }
    notifyListeners();
  }

  /// 开关 [attr]：选区里全都带 → 去掉；否则全部加上。折叠光标 = 改接下来输入的样式。
  void toggle(SrsRichAttr attr) {
    final bool on = !isActive(attr);
    _restyle((SrsRichFormat s) => s.withAttr(attr, on));
  }

  /// 设文字颜色（null = 默认颜色）。
  void setColor(int? argb) => _restyle((SrsRichFormat s) => s.withColor(argb));

  /// 当前选区（或光标处）的高亮色；选区里不一致时 null。
  int? get activeHighlight {
    final TextSelection sel = selection;
    if (!sel.isValid || sel.isCollapsed) {
      return (_pending ?? _styleBefore(sel.isValid ? sel.start : text.length))
          .highlight;
    }
    final int? first = _styles[sel.start].highlight;
    for (int i = sel.start; i < sel.end; i++) {
      if (_styles[i].highlight != first) return null;
    }
    return first;
  }

  /// 设高亮（null = 去掉高亮）。
  void setHighlight(int? argb) =>
      _restyle((SrsRichFormat s) => s.withHighlight(argb));

  // ------------------------------------------------------------ 注音

  /// 第 [index] 个字所在注音组的范围；不带注音返回 null。
  TextRange? _rubyGroupAt(int index) {
    if (index < 0 || index >= _styles.length) return null;
    final SrsRuby? ruby = _styles[index].ruby;
    if (ruby == null) return null;
    int start = index;
    int end = index + 1;
    while (start > 0 && _styles[start - 1].ruby == ruby) {
      start--;
    }
    while (end < _styles.length && _styles[end].ruby == ruby) {
      end++;
    }
    return TextRange(start: start, end: end);
  }

  /// 当前选区落在的那一组注音：选区整个在同一组里（折叠光标 = 紧挨光标前 / 后的字所在组）
  /// 返回这组的完整范围，否则 null。
  TextRange? get activeRubyRange {
    final TextSelection sel = selection;
    if (!sel.isValid) return null;
    if (sel.isCollapsed) {
      return _rubyGroupAt(sel.start - 1) ?? _rubyGroupAt(sel.start);
    }
    final TextRange? group = _rubyGroupAt(sel.start);
    if (group == null || sel.end > group.end) return null;
    return group;
  }

  /// [activeRubyRange] 那组的读音。
  String? get activeRubyReading {
    final TextRange? range = activeRubyRange;
    return range == null ? null : _styles[range.start].ruby!.reading;
  }

  /// 有没有注音。
  bool get hasRuby => _styles.any((SrsRichFormat s) => s.ruby != null);

  /// 全部注音组（按出现顺序）。
  List<({TextRange range, String reading})> get rubyGroups {
    final List<({TextRange range, String reading})> out =
        <({TextRange range, String reading})>[];
    int i = 0;
    while (i < _styles.length) {
      final TextRange? group = _rubyGroupAt(i);
      if (group == null) {
        i++;
        continue;
      }
      out.add((range: group, reading: _styles[i].ruby!.reading));
      i = group.end;
    }
    return out;
  }

  /// 给 [range] 里的字标注音 [reading]（空 = 去掉这段的注音）。范围里有换行（注音不跨行）
  /// 或越界时不改、返回 false。
  bool setRuby(TextRange range, String reading) {
    if (!range.isValid ||
        range.isCollapsed ||
        range.end > text.length ||
        text.substring(range.start, range.end).contains('\n')) {
      return false;
    }
    final String r = reading.replaceAll(RegExp(r'[\r\n]'), ' ').trim();
    SrsRuby? ruby;
    if (r.isNotEmpty) {
      int id = 0;
      for (final SrsRichFormat s in _styles) {
        if (s.ruby != null && s.ruby!.id > id) id = s.ruby!.id;
      }
      ruby = SrsRuby(id + 1, r);
    }
    for (int i = range.start; i < range.end; i++) {
      _styles[i] = _styles[i].withRuby(ruby);
    }
    notifyListeners();
    return true;
  }

  TextStyle _styleOf(SrsRichFormat s, bool composing, Color rubyColor) {
    final bool ruby = s.ruby != null && !s.underline && !composing;
    final List<TextDecoration> decorations = <TextDecoration>[
      if (s.underline || composing || ruby) TextDecoration.underline,
    ];
    return TextStyle(
      fontWeight: s.bold ? FontWeight.w700 : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
      decorationStyle: ruby ? TextDecorationStyle.dotted : null,
      decorationColor: ruby ? rubyColor : null,
      color: s.color == null ? null : Color(s.color!),
      backgroundColor: s.highlight == null ? null : Color(s.highlight!),
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String t = text;
    final TextRange composing = value.composing;
    final bool hasComposing =
        withComposing && composing.isValid && !composing.isCollapsed;
    bool inComposing(int i) =>
        hasComposing && i >= composing.start && i < composing.end;
    final Color rubyColor = Theme.of(context).colorScheme.primary;
    final List<TextSpan> children = <TextSpan>[];
    int i = 0;
    while (i < t.length) {
      final SrsRichFormat s = i < _styles.length
          ? _styles[i]
          : SrsRichFormat.plain;
      final bool c = inComposing(i);
      int j = i + 1;
      while (j < t.length &&
          (j < _styles.length ? _styles[j] : SrsRichFormat.plain) == s &&
          inComposing(j) == c) {
        j++;
      }
      children.add(
        TextSpan(text: t.substring(i, j), style: _styleOf(s, c, rubyColor)),
      );
      i = j;
    }
    return TextSpan(style: style, children: children);
  }
}
