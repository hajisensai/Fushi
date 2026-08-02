import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_file_ref.dart';
import 'package:hibiki/src/sync/sync_utils.dart';

/// 一次问清整个同步根的远端列举快照（增量同步 / TODO-2656）。
///
/// ## 它解决的问题
///
/// 在此之前，每一轮同步都对**每本书**发一次 `listSyncFiles`（WebDAV 一次 PROPFIND /
/// Drive 一次 files.list）。500 本书就是 500 次网络往返，哪怕一本都没动过——贵的从来
/// 不是「判断」，而是「为了拿到判断所需的那点文件名，逐本各发一次请求」。
///
/// ## 为什么不是「索引」
///
/// 一个显而易见的做法是让各设备把自己的观测写成索引文件，别人读索引来跳过某些书。
/// 那条路有个致命前提：**所有写远端的客户端都得如实更新索引**。这个前提对尚未升级的
/// 旧版本设备、第三方 ッツ 兼容客户端、以及用户在云盘网页端的手改都不成立；而一旦
/// 索引与远端实情不符，被跳过的那本书就漏掉了对端的更新——接着本地继续读、时间戳
/// 变新、按 LWW 覆盖远端，对端的进度**真的丢了**。跳过是单边不安全的操作，用一个靠
/// 自觉维持的协议去守护它，等于把性能问题换成了数据问题。
///
/// 所以这里不引入任何需要被信任的中间层：快照的内容**就是远端文件名本身**，与逐本
/// 列举拿到的是同一个东西，只是一次拿完。判据因此与改动前逐字相同，不存在「索引可不
/// 可信」这个问题，也不需要租约、版本号、周期性全量兜底或任何多写者并发语义。
///
/// ## 能力是可选的
///
/// 只有当后端能**廉价地**一次列举整棵树时才提供快照（Drive 的全空间 files.list、
/// Dropbox 的 recursive list_folder、WebDAV 的 `Depth: infinity`…）。做不到的后端返回
/// null，调用方原样走逐本列举——慢，但语义与今天完全一致。宁可慢，不可错。
class RemoteListingSnapshot {
  const RemoteListingSnapshot(this.folders);

  /// 同步根的直接子文件夹名 → 该文件夹下的条目。
  ///
  /// 书文件夹与保留命名空间（`__collections__` 等）**不在这里区分**：装配时无从、也
  /// 无需知道一个名字属于哪类，消费方按自己关心的名字来问即可。少一份「什么算保留
  /// 名」的副本，就少一处与 `isReservedSyncFolderName` 分叉的机会。
  ///
  /// 键不存在 与 键存在但列表为空 是两回事：前者远端没有这个文件夹，后者文件夹在但
  /// 还空着。
  final Map<String, List<AssetEntry>> folders;

  /// 某本书的同步三件套，语义与 `SyncBackend.listSyncFiles` 完全相同。
  ///
  /// **必须**走 [findSyncFileByPrefix]——各后端 `listSyncFiles` 用的就是这个 canonical
  /// matcher（HBK-AUDIT-085）。这里若另写一套前缀匹配，同一本书经快照和经逐本列举会
  /// 得到不同的三件套，于是同步方向随「走了哪条路」而变，且不会以异常的形式暴露。
  SyncFileTrio trioFor(String bookFolderName) {
    final List<SyncFileRef> files = <SyncFileRef>[
      for (final AssetEntry e
          in folders[bookFolderName] ?? const <AssetEntry>[])
        if (!e.isFolder) SyncFileRef(id: e.id, name: e.name),
    ];
    return SyncFileTrio(
      progress: findSyncFileByPrefix(files, 'progress_'),
      statistics: findSyncFileByPrefix(files, 'statistics_'),
      audioBook: findSyncFileByPrefix(files, 'audioBook_'),
    );
  }

  /// 某个保留命名空间下的条目，语义与 `SyncAssetStore.listChildren` 相同。
  /// 命名空间在远端尚不存在时返回空列表（与 `ensureNamespace` 后立刻列举同义）。
  List<AssetEntry> entriesOf(String folderName) =>
      folders[folderName] ?? const <AssetEntry>[];

  bool hasFolder(String folderName) => folders.containsKey(folderName);

  int get folderCount => folders.length;
}

/// 按「同步根的直接子文件夹名 + 其下文件」逐个投喂，装配出 [RemoteListingSnapshot]。
///
/// 各后端拿到的原始形态差别很大（Drive 是扁平的 id+parents，Dropbox 是带路径的递归
/// 条目，WebDAV 是一堆 href），但都能算出这两样。装配规则集中一份，避免每个后端各自
/// 解释一遍。
class RemoteListingBuilder {
  final Map<String, List<AssetEntry>> _folders = <String, List<AssetEntry>>{};

  /// 登记一个同步根的直接子文件夹。
  ///
  /// 显式登记的意义：一个已存在但还空着的文件夹，与一个根本不存在的文件夹，在
  /// [RemoteListingSnapshot.hasFolder] 上必须能区分。
  void addFolder(String name) {
    if (name.isEmpty) return;
    _folders.putIfAbsent(name, () => <AssetEntry>[]);
  }

  /// 登记 [parentName] 文件夹下的一个条目。
  ///
  /// [parentName] 为空 = 该条目直接躺在同步根下。那不属于任何书（是 BUG-619 的 spill
  /// 残留），丢弃：把它归给某本书会让那本书读到一份不属于它的 progress。
  void addEntry({
    required String parentName,
    required String name,
    required String id,
    bool isFolder = false,
    int? sizeBytes,
  }) {
    if (parentName.isEmpty || name.isEmpty) return;
    _folders.putIfAbsent(parentName, () => <AssetEntry>[]).add(
          AssetEntry(
              id: id, name: name, isFolder: isFolder, sizeBytes: sizeBytes),
        );
  }

  RemoteListingSnapshot build() => RemoteListingSnapshot(_folders);
}

/// 后端的**可选**能力：一次列举整个同步根。
///
/// 故意不放进 `SyncBackend` 主接口：那是所有后端都必须履行的契约，而这只是「能做到
/// 就做、做不到照旧」的加速。放进主接口会强迫七个后端和一大批测试替身全都实现一个
/// 它们根本提供不了的方法，把「可选」写成「必需」。
///
/// 调用方一律写成 `snapshot?.trioFor(key) ?? await listSyncFiles(folderId)`：两条路
/// 给出同一批文件名，快照缺席只是慢，绝不改变任何一本书的同步方向。
abstract interface class RemoteListingCapable {
  /// 一次列举整个同步根；**做不到 / 失败一律返回 null**，绝不抛。
  ///
  /// 只在后端能**廉价**做到时才实现（Drive 全空间 files.list、Dropbox recursive
  /// list_folder…）。若某后端只能靠逐个文件夹递归列举凑出全貌，那与逐本列举是同一个
  /// 成本，实现它没有意义。
  Future<RemoteListingSnapshot?> snapshotListing(String rootFolderId);
}
