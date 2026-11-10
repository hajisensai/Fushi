// 添加种子时的文件勾选模型（反馈 pR-icPGMJD：333 个文件的有声书合集只想下其中
// 一两本）。对话框只画，筛选 / 勾选 / 汇总 / 提交参数都在 TorrentFileSelection。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/torrent_file_selection.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';

List<InspectedTorrentFile> _files(Map<String, int> pathToLength) {
  int index = 0;
  return <InspectedTorrentFile>[
    for (final MapEntry<String, int> entry in pathToLength.entries)
      InspectedTorrentFile(
        index: index++,
        path: entry.key,
        length: entry.value,
      ),
  ];
}

void main() {
  final List<InspectedTorrentFile> pack = _files(<String, int>{
    'Book A/01 Opening.m4b': 100,
    'Book A/02 Chapter.m4b': 200,
    'Book B/01 Opening.m4b': 300,
    'Book B/cover.jpg': 4,
  });

  test('starts fully selected and submits null (whole torrent)', () {
    final TorrentFileSelection selection = TorrentFileSelection(pack);
    expect(selection.selectedCount, 4);
    expect(selection.selectedBytes, 604);
    expect(selection.totalBytes, 604);
    expect(selection.allSelected, isTrue);
    expect(selection.submission, isNull);
  });

  test('filter is case-insensitive and every term must match', () {
    final TorrentFileSelection selection = TorrentFileSelection(pack);
    expect(
      selection.filter('book b').map((InspectedTorrentFile f) => f.index),
      <int>[2, 3],
    );
    expect(
      selection
          .filter('  OPENING  a ')
          .map((InspectedTorrentFile f) => f.index),
      <int>[0],
    );
    expect(selection.filter(''), hasLength(4));
    expect(selection.filter('nothing-matches'), isEmpty);
  });

  test('select none + select all act on the filtered subset only', () {
    final TorrentFileSelection selection = TorrentFileSelection(pack);
    selection.setAll(selection.files, selected: false);
    expect(selection.noneSelected, isTrue);

    selection.setAll(selection.filter('book a'), selected: true);
    expect(selection.selectedCount, 2);
    expect(selection.selectedBytes, 300);
    expect(selection.submission, <int>{0, 1});

    // 在另一个筛选结果上「全不选」不碰 Book A 的勾选。
    selection.setAll(selection.filter('book b'), selected: false);
    expect(selection.submission, <int>{0, 1});
  });

  test('single toggles update count, bytes and submission', () {
    final TorrentFileSelection selection = TorrentFileSelection(pack);
    selection.setSelected(3, selected: false);
    expect(selection.isSelected(3), isFalse);
    expect(selection.selectedCount, 3);
    expect(selection.selectedBytes, 600);
    expect(selection.submission, <int>{0, 1, 2});

    selection.setSelected(3, selected: true);
    expect(selection.allSelected, isTrue);
    expect(selection.submission, isNull);
  });

  test('submission is a copy, not a live view of the selection', () {
    final TorrentFileSelection selection = TorrentFileSelection(pack);
    selection.setSelected(0, selected: false);
    final Set<int> submitted = selection.submission!;
    selection.setSelected(1, selected: false);
    expect(submitted, <int>{1, 2, 3});
  });

  test('disc files toggle as one unit (BUG-4245: discs download whole)', () {
    final TorrentFileSelection selection = TorrentFileSelection(
      _files(<String, int>{
        'Show/DISC1/BDMV/index.bdmv': 1,
        'Show/DISC1/BDMV/PLAYLIST/00001.mpls': 1,
        'Show/DISC1/BDMV/STREAM/00001.m2ts': 1000,
        'Show/DISC1/CERTIFICATE/id.bdmv': 1,
        'Show/extra.mkv': 50,
      }),
    );
    selection.setSelected(2, selected: false);
    // 取消盘里任何一个文件 = 整张盘都不下；盘外文件不受影响。
    expect(selection.submission, <int>{4});

    selection.setSelected(1, selected: true);
    expect(selection.allSelected, isTrue);

    selection.setAll(selection.filter('extra'), selected: false);
    selection.setAll(selection.filter('m2ts'), selected: false);
    expect(selection.noneSelected, isTrue);
    selection.setAll(selection.filter('m2ts'), selected: true);
    expect(selection.submission, <int>{0, 1, 2, 3});
  });
}
