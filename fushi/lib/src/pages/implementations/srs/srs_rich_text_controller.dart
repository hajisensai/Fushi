/// 笔记编辑页的富文本输入：一个 [TextEditingController]，额外为每个字符记一份行内样式
/// （[SrsRichStyle]），按样式画 [TextSpan]，并序列化回 Anki 写法的 HTML。
///
/// 为什么不用 WebView contenteditable：编辑页一屏十来个字段，每个字段一个 WebView 太重
/// （桌面 WebView2 / 移动端平台视图都是独立进程或纹理），且焦点 / 输入法 / 快捷键要跨
/// 平台视图边界桥接；这里的格式只有加粗 / 斜体 / 下划线 / 颜色，原生 [EditableText] 足够，
/// 输入法、撤销、选择、手柄焦点全部沿用 app 现有的文本框行为。
///
/// **往返不变**：没改过（文字与样式都与载入时相同）时 [html] 原样返回载入时的字符串，
/// 不经序列化——`<strong>` 不会被改写成 `<b>`、实体不会被重新转义。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_field_markup.dart';

class SrsRichTextController extends TextEditingController {
  SrsRichTextController._(this._original, SrsRichDoc doc)
    : _styles = List<SrsRichStyle>.of(doc.styles),
      _initialText = doc.text,
      _initialStyles = List<SrsRichStyle>.unmodifiable(doc.styles),
      super(text: doc.text);

  /// 从字段 HTML 建；不在子集里（见 [srsParseRichHtml]）返回 null。
  static SrsRichTextController? tryParse(String html) {
    final SrsRichDoc? doc = srsParseRichHtml(html);
    return doc == null ? null : SrsRichTextController._(html, doc);
  }

  final String _original;
  final String _initialText;
  final List<SrsRichStyle> _initialStyles;
  List<SrsRichStyle> _styles;

  /// 折叠光标下「接下来输入的字」的样式（点了加粗再打字）；移动光标即作废。
  SrsRichStyle? _pending;

  /// 逐字符样式（只读视图）。
  List<SrsRichStyle> get styles => List<SrsRichStyle>.unmodifiable(_styles);

  /// 和载入时相比改过没有。
  bool get dirty =>
      text != _initialText || !srsSameStyles(_styles, _initialStyles);

  /// 字段值：没改过 = 原样的载入值；改过 = 序列化。
  String get html => dirty ? srsRichToHtml(text, _styles) : _original;

  SrsRichStyle _styleBefore(int offset) {
    if (_styles.isEmpty) return SrsRichStyle.plain;
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
      final SrsRichStyle style = _pending ?? _styleBefore(prefix);
      _styles = <SrsRichStyle>[
        ..._styles.sublist(0, prefix),
        ...List<SrsRichStyle>.filled(inserted, style),
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

  void _restyle(SrsRichStyle Function(SrsRichStyle s) change) {
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
    _restyle((SrsRichStyle s) => s.withAttr(attr, on));
  }

  /// 设文字颜色（null = 默认颜色）。
  void setColor(int? argb) => _restyle((SrsRichStyle s) => s.withColor(argb));

  TextStyle _styleOf(SrsRichStyle s, bool composing) {
    final List<TextDecoration> decorations = <TextDecoration>[
      if (s.underline || composing) TextDecoration.underline,
    ];
    return TextStyle(
      fontWeight: s.bold ? FontWeight.w700 : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
      color: s.color == null ? null : Color(s.color!),
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
    final List<TextSpan> children = <TextSpan>[];
    int i = 0;
    while (i < t.length) {
      final SrsRichStyle s = i < _styles.length
          ? _styles[i]
          : SrsRichStyle.plain;
      final bool c = inComposing(i);
      int j = i + 1;
      while (j < t.length &&
          (j < _styles.length ? _styles[j] : SrsRichStyle.plain) == s &&
          inComposing(j) == c) {
        j++;
      }
      children.add(TextSpan(text: t.substring(i, j), style: _styleOf(s, c)));
      i = j;
    }
    return TextSpan(style: style, children: children);
  }
}
