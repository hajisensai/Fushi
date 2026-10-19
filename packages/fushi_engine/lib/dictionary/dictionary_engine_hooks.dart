/// 词典 FFI 引擎（`fushidicts`，住 `packages/fushi_dictionary` 的重文件）对引擎侧
/// 库操作的唯一触点。
///
/// host 的词典导入/删除要先让引擎释放对 `blobs.bin` / `hash.table` 的
/// `MapViewOfFile` 映射（Windows 拒绝以写方式打开被映射文件，BUG-1756），完事再
/// `refreshDictionaryCache` 装回。引擎不能依赖 `fushi_dictionary` 的重文件，所以
/// 「释放映射」这一件事收成一个可注入的钩子：
/// - Flutter app / 无头服务端：`releaseDictionaryMappings =
///   FushiDicts.releaseAllMappingsAndSettle`。
/// - 没装词典引擎的宿主：默认 no-op。
///
/// 异步：原生句柄被后台 isolate 借着时（浏览器扩展的后台分词，HBK-AUDIT-009）destroy
/// 只是退役，映射要等最后一个借用归还才解除。返回的 Future 完成时映射已全部解除，
/// 调用方 await 之后才能删 / 覆盖词典文件。
library;

Future<void> Function() releaseDictionaryMappings = () async {};
