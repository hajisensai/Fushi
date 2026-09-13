/// 词典 FFI 引擎（`fushidicts`，住 `packages/fushi_dictionary` 的重文件）对引擎侧
/// 库操作的唯一触点。
///
/// host 的词典导入/删除要先让引擎释放对 `blobs.bin` / `hash.table` 的
/// `MapViewOfFile` 映射（Windows 拒绝以写方式打开被映射文件，BUG-1756），完事再
/// `refreshDictionaryCache` 装回。引擎不能依赖 `fushi_dictionary` 的重文件，所以
/// 「释放映射」这一件事收成一个可注入的钩子：
/// - Flutter app：`releaseDictionaryMappings = FushiDicts.releaseAllMappings`。
/// - 无头服务端（第 0 期不装词典引擎）：默认 no-op。
library;

void Function() releaseDictionaryMappings = () {};
