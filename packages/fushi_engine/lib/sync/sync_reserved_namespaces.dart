import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;

/// 同步根（所有后端共用的 `fushi-data/`）下的这个一级目录名是不是**保留命名空间**，不是书文件夹
/// （BUG-4991 / BUG-5007 的唯一真相源）。
///
/// 读它的两处必须一致，以前各写一份、已经漂移过一次：
/// - 客户端列远端书（`isReservedSyncFolderName`：对比弹窗、云端书架、导入远端书）——漏一个，这个
///   命名空间就会被当成「只剩元数据的远端书」列出来，用户在对比弹窗里一点「删远端」就把所有设备的
///   共享数据删了（BUG-5007：`__settings__` 与 `fushi-srs` 曾经漏掉）。
/// - 互联 host 启动时清理已死的文件箱书文件夹（`pruneDeadInterconnectFileBox`）——漏一个就直接删掉。
///
/// 判据：`__x__` 形状（全部资产命名空间：`__dictionaries__` `__local_audio__` `__aggregate__`
/// `__collections__` `__videos__` `__tombstones__` `__fonts__` `__settings__` `__pending_mines__`，以及
/// 自动备份的云端副本 `__backups__`），
/// 外加唯一不是这个形状的复习同步命名空间 `fushi-srs`。**新命名空间一律按 `__x__` 起名**，起了就
/// 自动受保护；守卫 `fushi/test/sync/interconnect_file_box_prune_reserved_guard_test.dart` 扫源码里
/// 全部命名空间常量逐个核对。
bool isReservedSyncNamespaceName(String name) =>
    (name.length > 4 && name.startsWith('__') && name.endsWith('__')) ||
    name == kSrsSync2Namespace;
