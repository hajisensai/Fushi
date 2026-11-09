/// 所有同步后端（云盘 + 局域网互联）共用的同步根文件夹名。
///
/// 历史上叫 `ttu-reader-data`（app 起步于 ttu-ebook-reader 分支），后来是 `hibiki-data`，现在是 `fushi-data`
/// （从旧根迁过来，见 app 的 `kLegacySyncRootFolderName`）。一个库必须在所有后端上同步得一模一样，所以每个
/// 后端都从这个常量取根名，不许写死字面量。互联主机磁盘上是 `<sync-data>/fushi-data/`。
library;

const String kSyncRootFolderName = 'fushi-data';
