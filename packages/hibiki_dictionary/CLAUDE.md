[根目录](../../CLAUDE.md) > [packages](../) > **hibiki_dictionary**

# hibiki_dictionary

## 模块职责

词典引擎模块：通过 C++ FFI (`hoshidicts`) 实现高性能词典查询，支持 Yomichan/Yomitan、ABBYY Lingvo、Migaku、MDict 等多种词典格式的导入和解析。同时提供日语（去屈折/振假名/音高）的语言处理工具。

## 入口与启动

- 库入口：`lib/hibiki_dictionary.dart`
- FFI 核心：`lib/src/engine/hoshidicts.dart` -- 通过 `dart:ffi` 调用 C++ `hoshidicts` 原生库。
- FFI 绑定：`lib/src/ffi/hoshidicts_ffi_bindings.dart` -- 自动/手动生成的 FFI 函数签名。
- 应用启动时调用 `HoshiDicts.preloadTransforms()` 预加载语言变换表。

## C++ 引擎真实位置（不在本包）

- **本包只剩纯 Dart**：`lib/src/` 下仅 `engine/`、`ffi/`、`formats/`、`language/`、`models/` 五个目录，无任何 `.cpp/.cc/.h`；FFI 绑定在 `lib/src/ffi/hoshidicts_ffi_bindings.dart`。
- **C++ 引擎源码全在仓库根 `native/hoshidicts/`**：`hoshidicts_src/`（`deinflector.cpp` / `importer.cpp` / `lookup.cpp` / `query.cpp` / `popup_json.cpp` 等实现）、`hoshidicts_include/`（头文件）、`hoshidicts_ffi.cpp`（C ABI 导出，供 Dart FFI）、`hoshidicts_jni.cpp`（Android JNI 桥）、`CMakeLists.txt`（构建）；`hoshidicts_external/` 为 vendored 第三方依赖（glaze / libdeflate / unordered_dense / utf8proc / utfcpp / xxHash / zstd）；`UPSTREAM.md` 记上游同步基线。
- **改 C++ 引擎行为（查询/导入/去屈折/解析）去 `native/hoshidicts/`，不在本包**；本包只做 Dart 侧绑定、格式注册与语言处理封装。

## 对外接口

- `HoshiDicts` -- 静态类，提供词典查询核心 API（search / import / delete）。
- `Dictionary` -- 词典抽象与实例管理。
- `DictionaryUtils` -- 词典工具函数。
- `DictionaryFormat` + 各格式实现 -- 词典格式解析注册。
- `DictionaryDownloader` -- 在线词典下载支持。
- `Language`（abstract）/ `JapaneseLanguage` -- 语言处理抽象与实现（当前 `targetLanguage` 钉死日语，`EnglishLanguage` / `ChineseLanguage` 子类已移除）。
- `LanguageUtils` -- 通用语言工具（kana 检测、分词等）。
- `DictionaryEntry` / `DictionarySearchResult` -- 查询结果数据模型。
- `DictionaryOperationsParams` -- 词典操作参数。

## 关键依赖与配置

- `ffi: ^2.1.3` -- dart:ffi 基础。
- `hibiki_core` -- 数据库层依赖。
- `kana_kit: ^2.0.0` -- 假名/罗马字转换。
- `ruby_text` -- 注音文字渲染。
- `archive / async_zip / flutter_archive` -- 压缩包处理（词典导入）。
- `dio` -- HTTP 下载。

## 数据模型

- `HoshiTermResult` -- FFI 查询返回的词条结果（expression / reading / glossaries / frequencies / pitches）。
- `DictionaryEntry` -- Dart 层的词典条目。
- `DictionarySearchResult` -- 搜索结果集合。
- 词典元数据存储在 `hibiki_core` 的 `DictionaryMetadata` 表。

## 测试与质量

测试位于 `hibiki/test/dictionary/`：
- `dictionary_entry_test.dart`
- `dictionary_search_result_test.dart`

## 相关文件清单

- `lib/hibiki_dictionary.dart` -- 库入口（导出全部公开 API）
- `lib/src/engine/hoshidicts.dart` -- FFI 核心
- `lib/src/engine/dictionary.dart` -- 词典抽象
- `lib/src/ffi/hoshidicts_ffi_bindings.dart` -- FFI 绑定
- `lib/src/formats/` -- 各词典格式解析器
- `lib/src/language/` -- 语言处理实现
- `lib/src/models/` -- 数据模型

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
