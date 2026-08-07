/// 测试支撑：本地做种 rig（确定性、零外网）。
///
/// 供本包与 app 侧集成测试复用：生成确定性内容文件 → make_torrent →
/// 起本地做种 session → 被测方用磁力 + connect_peer 从它下载。
library;

export 'src/testing/local_seed_rig.dart';
