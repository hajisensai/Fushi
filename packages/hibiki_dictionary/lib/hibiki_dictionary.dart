library hibiki_dictionary;

export 'src/engine/dictionary.dart';
export 'src/engine/dictionary_utils.dart';
export 'src/engine/hoshidicts.dart';
// HBK-AUDIT-098: do NOT export the raw FFI bindings. The Ffi* Struct mirrors
// hold Pointer<Utf8> fields owned by native malloc/free and are only valid
// between an FFI call and its matching free. Exposing them as package public
// API would let consumers hold pointers past the free boundary (use-after-free
// the type system presents as valid). hoshidicts.dart imports the bindings via
// a relative path; only the safe HoshiDicts wrapper + Hoshi* data classes are public.
export 'src/formats/dictionary_format.dart';
export 'src/formats/dictionary_downloader.dart';
export 'src/formats/dictionary_update_service.dart';
export 'src/formats/yomichan_dictionary_format.dart';
export 'src/formats/abbyy_lingvo_format.dart';
export 'src/formats/migaku_dictionary_format.dart';
export 'src/formats/mdict_format.dart';
export 'src/language/language.dart';
export 'src/language/language_utils.dart';
export 'src/language/ruby_text.dart';
export 'src/language/implementations/japanese_language.dart';
export 'src/models/dictionary_entry.dart';
export 'src/models/dictionary_operations_params.dart';
export 'src/models/dictionary_search_result.dart';
export 'src/models/structured_content.dart';
