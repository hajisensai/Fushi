/// 词典 FFI 引擎（`fushidicts`，住 `packages/fushi_dictionary` 的重文件）对引擎侧
/// 库操作的唯一触点。
///
/// host 的词典导入/删除要先让引擎释放对 `blobs.bin` / `hash.table` 的
/// `MapViewOfFile` 映射（Windows 拒绝以写方式打开被映射文件，BUG-1756），完事再
/// `refreshDictionaryCache` 装回。引擎不能依赖 `fushi_dictionary` 的重文件，所以
/// 「在映射释放的状态下删 / 覆盖词典文件」这一件事收成一个可注入的作用域钩子：
/// - Flutter app / 无头服务端：`withDictionaryMappingsReleased =
///   FushiDicts.withMappingsReleased`。
/// - 没装词典引擎的宿主：默认直接跑 body。
///
/// 是作用域而不是一次性的「释放」调用：释放与真正删 / 写之间隔着 await（等后台
/// isolate 的借用归还、异步 delete、占用重试），这期间排下的引擎装载必须推迟到
/// body 结束，否则正被删 / 覆盖的文件又被映射上（HBK-AUDIT-009）。
library;

/// 在词典文件映射保持释放的作用域里跑 [body]；body 里删 / 覆盖词典文件。
Future<T> Function<T>(Future<T> Function() body)
withDictionaryMappingsReleased = _runWithoutDictionaryEngine;

Future<T> _runWithoutDictionaryEngine<T>(Future<T> Function() body) => body();
