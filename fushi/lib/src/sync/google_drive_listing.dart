import 'package:fushi/src/sync/sync_remote_listing.dart';

/// Drive `files.list` 返回的一条（只取列举需要的字段）。
typedef DriveListedFile = ({
  String id,
  String name,
  List<String> parents,
  bool isFolder,
});

/// 跑一页 `files.list`：[query] 是完整的 `q`，[pageToken] 为 null 取第一页。
typedef DriveListPage =
    Future<({List<DriveListedFile> files, String? nextPageToken})> Function(
      String query,
      String? pageToken,
    );

/// 一条 `q` 里最多并多少个 `'<id>' in parents`。Drive 的 `files.list` 是 GET，`q` 进
/// URL；文件夹 id 约 30–70 字符，40 个 OR 子句约 3 KB，远在 URL 上限之内。
const int kDriveListingParentBatch = 40;

/// 列出同步根下**深度 1 + 深度 2** 的全部条目，组成 [RemoteListingSnapshot]。
///
/// 快照只用得到这两层：根的直接子文件夹（书 / 命名空间），以及它们各自的直接子项
/// （`progress_*` / `statistics_*` / 内容文件 / 资产）。旧实现用 `q=trashed=false` 把
/// 整个 appData 空间逐页拉完、再在本地丢掉更深的层级——复习同步 v2 把操作分段写在
/// `fushi-srs/<profileUid>/v2/devices/<设备>/…`，一个活跃用户就有数万个文件，于是每轮
/// 同步开头先翻几十页与书无关的分段（用户实测 8 万个文件，≈80 页、整整 5 分钟），这段
/// 时间编排器一个阶段 tick 都发不出来，进度条停在「正在准备同步」。
///
/// 这里只问两层：先列根的直接子项，再把子文件夹按 [parentBatch] 个一组 OR 成一条查询
/// 列它们的直接子项。请求数 = 根的页数 + ⌈子文件夹数 / [parentBatch]⌉（每组再按页），
/// 与更深层级的文件数无关。结果与旧实现逐条一致（多父条目按每个落在根下的父各记一次）。
Future<RemoteListingSnapshot> listDriveSyncRoot({
  required String rootFolder,
  required DriveListPage listPage,
  int parentBatch = kDriveListingParentBatch,
}) async {
  Future<List<DriveListedFile>> listAll(String query) async {
    final List<DriveListedFile> out = <DriveListedFile>[];
    String? pageToken;
    do {
      final page = await listPage(query, pageToken);
      out.addAll(page.files);
      pageToken = page.nextPageToken;
    } while (pageToken != null);
    return out;
  }

  final RemoteListingBuilder builder = RemoteListingBuilder();
  final Map<String, String> topFolderNameById = <String, String>{};
  for (final DriveListedFile f in await listAll(
    "trashed=false and '${escapeDriveQuery(rootFolder)}' in parents",
  )) {
    // 根下的散文件不属于任何书文件夹，快照里本来就不收（与旧实现一致）。
    if (!f.isFolder) continue;
    topFolderNameById[f.id] = f.name;
    // 先登记文件夹：空文件夹才能与「不存在的文件夹」区分开。
    builder.addFolder(f.name);
  }

  final List<String> topIds = topFolderNameById.keys.toList();
  for (int i = 0; i < topIds.length; i += parentBatch) {
    final List<String> batch = topIds.sublist(
      i,
      i + parentBatch > topIds.length ? topIds.length : i + parentBatch,
    );
    final String parentsClause = batch
        .map((String id) => "'${escapeDriveQuery(id)}' in parents")
        .join(' or ');
    for (final DriveListedFile f in await listAll(
      'trashed=false and ($parentsClause)',
    )) {
      for (final String parent in f.parents) {
        final String? parentName = topFolderNameById[parent];
        if (parentName == null) continue;
        builder.addEntry(
          parentName: parentName,
          name: f.name,
          id: f.id,
          isFolder: f.isFolder,
        );
      }
    }
  }
  return builder.build();
}

/// Drive `q` 字符串字面量转义（单引号与反斜杠）。
String escapeDriveQuery(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
