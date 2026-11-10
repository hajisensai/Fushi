import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/media/video/download/video_download_disc_payload.dart'
    show DownloadDiscRoot, downloadDiscRootOf, planDownloadDiscRoots;

/// 添加种子时的文件勾选状态（qBittorrent 式「只下选中的文件」）。
///
/// 纯 Dart、无 UI：对话框只负责画，筛选 / 勾选 / 全选 / 汇总 / 提交参数都在这里
/// 算一遍，widget 测试和单元测试钉的是同一份逻辑。
///
/// 原盘（BDMV / VIDEO_TS / ISO）只能整张下（BUG-4245，管线入队时也会扩成整盘，
/// 见 `expandDownloadSelectionToWholeDiscs`）：这里把同一张盘的文件绑成一组，勾 /
/// 取消其中任何一个就整组一起变，界面上看到的已选数量与大小 = 实际会下载的。
class TorrentFileSelection {
  TorrentFileSelection(List<InspectedTorrentFile> files)
    : files = List<InspectedTorrentFile>.unmodifiable(files),
      _selected = <int>{for (final InspectedTorrentFile f in files) f.index},
      _groupOf = _discGroups(files),
      totalBytes = files.fold<int>(
        0,
        (int sum, InspectedTorrentFile f) => sum + f.length,
      );

  /// 种子里的全部文件（按 metainfo 顺序）。
  final List<InspectedTorrentFile> files;

  /// 全部文件总大小。
  final int totalBytes;

  final Set<int> _selected;

  /// 文件 index → 它所在原盘的全部文件 index（不在原盘里的文件没有条目）。
  final Map<int, Set<int>> _groupOf;

  static Map<int, Set<int>> _discGroups(List<InspectedTorrentFile> files) {
    final List<DownloadDiscRoot> roots = planDownloadDiscRoots(
      files.map((InspectedTorrentFile f) => f.path),
    );
    if (roots.isEmpty) return const <int, Set<int>>{};
    final Map<DownloadDiscRoot, Set<int>> members =
        <DownloadDiscRoot, Set<int>>{};
    for (final InspectedTorrentFile file in files) {
      final DownloadDiscRoot? root = downloadDiscRootOf(file.path, roots);
      if (root == null) continue;
      (members[root] ??= <int>{}).add(file.index);
    }
    return <int, Set<int>>{
      for (final Set<int> group in members.values)
        for (final int index in group) index: Set<int>.unmodifiable(group),
    };
  }

  Iterable<int> _expand(int index) => _groupOf[index] ?? <int>[index];

  bool isSelected(int index) => _selected.contains(index);

  /// 勾选 / 取消单个文件（原盘文件连同整张盘）。
  void setSelected(int index, {required bool selected}) {
    if (selected) {
      _selected.addAll(_expand(index));
    } else {
      _selected.removeAll(_expand(index));
    }
  }

  /// 把 [subset]（通常是当前筛选结果）全部勾上 / 全部取消；筛选之外的文件
  /// 保持原样——「搜出这本书 → 全选」不该把别的书的勾选冲掉。
  void setAll(Iterable<InspectedTorrentFile> subset, {required bool selected}) {
    for (final InspectedTorrentFile file in subset) {
      setSelected(file.index, selected: selected);
    }
  }

  /// 按文件名（种子内相对路径，不分大小写）筛选；空白分隔的多个词须全部命中。
  /// 空查询 = 全部文件。
  List<InspectedTorrentFile> filter(String query) {
    final List<String> terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String term) => term.isNotEmpty)
        .toList(growable: false);
    if (terms.isEmpty) return files;
    return <InspectedTorrentFile>[
      for (final InspectedTorrentFile file in files)
        if (terms.every(file.path.toLowerCase().contains)) file,
    ];
  }

  int get selectedCount => _selected.length;

  int get selectedBytes => files.fold<int>(
    0,
    (int sum, InspectedTorrentFile f) =>
        _selected.contains(f.index) ? sum + f.length : sum,
  );

  bool get allSelected => _selected.length == files.length;

  bool get noneSelected => _selected.isEmpty;

  /// 交给 `VideoDownloadManualEnqueueRequest.selectedFileIndexes` 的值：全选 =
  /// null（整颗 torrent，按普通任务建）；否则是选中的 index 集合。一个都没选
  /// 时不该提交（调用方用 [noneSelected] 挡住提交按钮）。
  Set<int>? get submission => allSelected ? null : Set<int>.of(_selected);
}
