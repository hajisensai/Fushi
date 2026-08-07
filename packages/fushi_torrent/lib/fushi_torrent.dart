/// fushi_torrent — 内置 libtorrent 引擎的 FFI 绑定与高层封装（阶段1b：
/// 磁力 → 元数据 → 顺序下载 → 进度 → 完成 + 边下边播原语）。
library;

export 'src/embedded_torrent_engine.dart';
export 'src/ffi/hibiki_torrent_bindings.dart';
