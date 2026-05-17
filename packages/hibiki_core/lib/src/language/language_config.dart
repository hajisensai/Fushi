import 'package:flutter/painting.dart';

/// Minimal language metadata — no dictionary/search operations.
/// Full Language class with textToWords(), prepareSearchResults() etc.
/// lives in hibiki_dictionary where it can access hoshidicts FFI.
abstract class LanguageConfig {
  String get languageName;
  String get languageCode;
  String get threeLetterCode;
  String get countryCode;
  TextDirection get textDirection;
  bool get preferVerticalReading;
  bool get isSpaceDelimited;
  TextBaseline get textBaseline;
  String get helloWorld;
  String get defaultFontFamily;
}
