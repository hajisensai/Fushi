/// fushi_dictionary 的**零 Flutter** 子集：查询结果模型（[DictionaryEntry] /
/// [DictionarySearchResult]）、fushidicts 结果数据类（`Fushi*Result` 等）与变形描述
/// i18n 表。无头服务端（`packages/fushi_server`，`dart compile exe`）和纯 Dart 引擎
/// `packages/fushi_engine` 只 import 本 barrel；任何 `package:flutter/...`（含
/// foundation）进到本闭包都会传递拖进 `dart:ui` 编不过。
///
/// `engine/fushidicts.dart`（FFI 引擎封装）也在这里：变形表的 rootBundle 读取经条件
/// import 只在 Flutter 宿主选中，纯 Dart 宿主改用 `FushiDicts.preloadTransformsFrom`。
/// 查词结果构建（`buildResultFromLookup` / `buildPopupJsonFromLookup`）在
/// `language/language.dart`（已零 Flutter；`Language` 抽象类搬到 `language_base.dart`）。
///
/// 不在这里的：`engine/dictionary.dart` / `language/language_base.dart`（material）、`formats/*`
/// （file_picker / flutter_archive / widgets）、`language/ruby_text.dart` 与
/// `language_utils.dart`（`RubyTextData` 持 `TextStyle` / `TextDirection`）——
/// 这些只从 `fushi_dictionary.dart` 导出。
library fushi_dictionary_core;

export 'src/engine/fushidicts.dart';
export 'src/engine/fushidicts_models.dart';
export 'src/language/language.dart';
export 'src/language/transform_description_i18n.dart';
export 'src/models/dictionary_entry.dart';
export 'src/models/dictionary_search_result.dart';
