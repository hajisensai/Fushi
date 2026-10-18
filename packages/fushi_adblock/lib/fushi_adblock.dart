/// 网页广告 / 跟踪拦截：Brave adblock-rust 的纯 Dart FFI 封装 + 过滤列表管理
/// （无 Flutter / 插件依赖；WebView 接线在 app 侧 `fushi/lib/src/web_adblock/`）。
library;

export 'src/adblock_engine_loader.dart';
export 'src/adblock_filter_list_service.dart';
export 'src/ffi/fushi_adblock_bindings.dart'
    show FushiAdblockBindings, FadbEngine;
export 'src/fushi_adblock_engine.dart';
export 'src/fushi_adblock_library.dart';
