/// 同步后端类型（持久化值 = `name`，冻结：pref `sync_backend_type` 存的是它）。
/// 从 app 的 sync_backend.dart 抽出：引擎的 [SyncChannelScope] 要按它分账，
/// 而 sync_backend.dart 拖着全部云盘实现。
library;

enum SyncBackendType {
  googleDrive,
  fushiServer,
  webDav,
  oneDrive,
  dropbox,
  ftp,
  sftp,
}
