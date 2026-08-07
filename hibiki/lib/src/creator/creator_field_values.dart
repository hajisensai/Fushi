import 'package:fushi/creator.dart';

/// A collection of values that can be used to mutate the current context of
/// the creator.
class CreatorFieldValues {
  /// Initialise an immutable collection of the final parameters.
  ///
  /// HBK-AUDIT-078: 防御性复制两张 map，使 [textValues]/[extraValues] 真正
  /// 不可被外部别名修改（文档声称 "immutable collection"，此前却直接存引用）。
  CreatorFieldValues({
    Map<Field, String> textValues = const {},
    Map<String, String> extraValues = const {},
  })  : textValues = Map<Field, String>.unmodifiable(textValues),
        extraValues = Map<String, String>.unmodifiable(extraValues);

  /// Creates a deep copy of this context but with the given fields replaced
  /// with the new values.
  ///
  /// HBK-AUDIT-078: 两张 map 都交给构造函数做防御性复制（之前只复制
  /// textValues，extraValues 直接按引用透传，导致拷贝与原对象共享同一张
  /// extraValues，违反文档承诺的 deep copy 语义）。
  CreatorFieldValues copyWith({
    Map<Field, String>? textValues,
    Map<String, String>? extraValues,
  }) {
    return CreatorFieldValues(
      textValues: textValues ?? this.textValues,
      extraValues: extraValues ?? this.extraValues,
    );
  }

  /// A map of text values to override for certain supplied key fields.
  final Map<Field, String> textValues;

  /// Raw key-value pairs from the popup (e.g. singleGlossaries, selectedDictionary).
  final Map<String, String> extraValues;

  /// Whether or not to allow the export button to be pressed.
  ///
  /// Instance-deterministic: depends only on this object's text values.
  bool get isExportable {
    for (String value in textValues.values) {
      if (value.isNotEmpty) {
        return true;
      }
    }

    return false;
  }
}
