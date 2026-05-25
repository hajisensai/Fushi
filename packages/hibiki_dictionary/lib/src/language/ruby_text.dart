import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class RubyTextData {
  const RubyTextData(
    this.text, {
    this.ruby,
    this.style,
    this.rubyStyle,
    this.textDirection = TextDirection.rtl,
  });

  final String text;
  final String? ruby;
  final TextStyle? style;
  final TextStyle? rubyStyle;
  final TextDirection textDirection;

  RubyTextData copyWith({
    String? text,
    String? ruby,
    TextStyle? style,
    TextStyle? rubyStyle,
    TextDirection? textDirection,
  }) =>
      RubyTextData(
        text ?? this.text,
        ruby: ruby ?? this.ruby,
        style: style ?? this.style,
        rubyStyle: rubyStyle ?? this.rubyStyle,
        textDirection: textDirection ?? this.textDirection,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RubyTextData &&
          text == other.text &&
          ruby == other.ruby &&
          style == other.style &&
          rubyStyle == other.rubyStyle &&
          textDirection == other.textDirection;

  @override
  int get hashCode => Object.hash(text, ruby, style, rubyStyle, textDirection);
}

class _RubySpanWidget extends StatelessWidget {
  const _RubySpanWidget(
    this.data, {
    this.indexStyle,
    this.indexAction,
  });

  final RubyTextData data;
  final TextStyle Function(int, String)? indexStyle;
  final void Function(int, String)? indexAction;

  @override
  Widget build(BuildContext context) {
    final defaultTextStyle = DefaultTextStyle.of(context).style;
    final boldTextOverride = MediaQuery.boldTextOf(context);

    var effectiveTextStyle = data.style;
    if (effectiveTextStyle == null || effectiveTextStyle.inherit) {
      effectiveTextStyle = defaultTextStyle.merge(effectiveTextStyle);
    }
    if (boldTextOverride) {
      effectiveTextStyle = effectiveTextStyle
          .merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    assert(effectiveTextStyle.fontSize != null, 'must have a font size.');
    final defaultRubyTextStyle = effectiveTextStyle.merge(
      TextStyle(fontSize: effectiveTextStyle.fontSize! / 1.5),
    );

    var effectiveRubyTextStyle = data.rubyStyle;
    if (effectiveRubyTextStyle == null || effectiveRubyTextStyle.inherit) {
      effectiveRubyTextStyle =
          defaultRubyTextStyle.merge(effectiveRubyTextStyle);
    }
    if (boldTextOverride) {
      effectiveRubyTextStyle = effectiveRubyTextStyle
          .merge(const TextStyle(fontWeight: FontWeight.bold));
    }

    final ruby = data.ruby;
    final text = data.text;
    if (ruby != null &&
        effectiveTextStyle.letterSpacing == null &&
        effectiveRubyTextStyle.letterSpacing == null &&
        ruby.length >= 2 &&
        text.length >= 2) {
      final rubyWidth = _measurementWidth(
        ruby,
        effectiveRubyTextStyle,
        textDirection: data.textDirection,
      );
      final textWidth = _measurementWidth(
        text,
        effectiveTextStyle,
        textDirection: data.textDirection,
      );

      if (textWidth > rubyWidth) {
        final newLetterSpacing = (textWidth - rubyWidth) / ruby.length;
        effectiveRubyTextStyle = effectiveRubyTextStyle
            .merge(TextStyle(letterSpacing: newLetterSpacing));
      } else {
        final newLetterSpacing = (rubyWidth - textWidth) / text.length;
        effectiveTextStyle = effectiveTextStyle
            .merge(TextStyle(letterSpacing: newLetterSpacing));
      }
    }

    final texts = <Widget>[];
    if (data.ruby != null) {
      texts.add(
        Text(
          data.ruby!,
          textAlign: TextAlign.center,
          style: effectiveRubyTextStyle,
        ),
      );
    }

    texts.add(
      Text.rich(
        TextSpan(
          children: text.characters.indexed.map((e) {
            final (index, character) = e;
            final charStr = String.fromCharCodes(character.runes);
            return TextSpan(
              text: charStr,
              style: effectiveTextStyle!
                  .merge(indexStyle?.call(index, charStr)),
              recognizer: TapGestureRecognizer()
                ..onTapDown = (details) {
                  indexAction?.call(index, charStr);
                },
            );
          }).toList(),
        ),
        textAlign: TextAlign.center,
        style: effectiveTextStyle,
      ),
    );

    return Column(children: texts);
  }
}

class RubyText extends StatelessWidget {
  const RubyText(
    this.data, {
    super.key,
    this.spacing = 0.0,
    this.style,
    this.rubyStyle,
    this.textAlign,
    this.textDirection,
    this.softWrap,
    this.overflow,
    this.maxLines,
    this.indexStyle,
    this.indexAction,
  });

  final List<RubyTextData> data;
  final double spacing;
  final TextStyle? style;
  final TextStyle? rubyStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final bool? softWrap;
  final TextOverflow? overflow;
  final int? maxLines;
  final TextStyle Function(int, String)? indexStyle;
  final void Function(int, String)? indexAction;

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(
          children: data
              .map<InlineSpan>(
                (RubyTextData d) => WidgetSpan(
                  child: _RubySpanWidget(
                    d.copyWith(
                      style: style,
                      rubyStyle: rubyStyle,
                      textDirection: textDirection,
                    ),
                    indexAction: indexAction,
                    indexStyle: indexStyle,
                  ),
                ),
              )
              .toList(),
        ),
        textAlign: textAlign,
        textDirection: textDirection,
        softWrap: softWrap,
        overflow: overflow,
        maxLines: maxLines,
      );
}

double _measurementWidth(
  String text,
  TextStyle style, {
  TextDirection textDirection = TextDirection.rtl,
}) {
  final textPainter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: textDirection,
    textAlign: TextAlign.center,
  )..layout();
  return textPainter.width;
}
