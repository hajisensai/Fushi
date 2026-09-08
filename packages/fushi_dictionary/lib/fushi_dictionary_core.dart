/// fushi_dictionary 的**零 Flutter** 子集：查询结果模型（[DictionaryEntry] /
/// [DictionarySearchResult]）、fushidicts 结果数据类（`Fushi*Result` 等）与变形描述
/// i18n 表。无头服务端（`packages/fushi_server`，`dart compile exe`）和纯 Dart 引擎
/// `packages/fushi_engine` 只 import 本 barrel；任何 `package:flutter/...`（含
/// foundation）进到本闭包都会传递拖进 `dart:ui` 编不过。
///
/// 不在这里的：`engine/fushidicts.dart`（flutter services `rootBundle` + foundation）、
/// `engine/dictionary.dart` / `language/language.dart`（material）、`formats/*`
/// （file_picker / flutter_archive / widgets）、`language/ruby_text.dart` 与
/// `language_utils.dart`（`RubyTextData` 持 `TextStyle` / `TextDirection`）——
/// 这些只从 `fushi_dictionary.dart` 导出。
library fushi_dictionary_core;

export 'src/engine/fushidicts_models.dart';
export 'src/language/transform_description_i18n.dart';
export 'src/models/dictionary_entry.dart';
export 'src/models/dictionary_search_result.dart';
