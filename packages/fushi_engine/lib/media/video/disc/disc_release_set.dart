// 同一发布的多张蓝光盘怎么并成一个剧集单元。纯函数，不碰文件系统与数据库。
//
// 一部 TV 动画的蓝光发布是几张盘（`Disc 1` / `Disc 2`，盘内标题 `…上巻` / `…下巻`）。
// 每张盘各建一个合集时，库里是几个互不相干的条目，各自绑到同一部作品、各自从第 1 集
// 数起。这里把「同一上级目录下、去掉卷标后同名」的剧集盘分到一组：一组一个合集，
// 成员按盘序 × 盘内集序排，集号由刮削协调器按这个顺序连续编下去。
//
// 只并「有被切成集的播放列表」的盘（`BlurayTitle.isEpisode`）：那是本功能新引入的
// 形态，没有存量合集可破坏。自带逐集播放列表的多卷盘维持一卷一个合集（见
// `docs/specs/2026-11-15-bluray-playitem-episodes.md` §7-D3）。

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';

/// 盘名 / 发布目录名尾部的卷标：`上巻` `下巻` `第2巻` `Vol.1` `Disc 2` `BD1`。
/// `前編` / `後編` 不在内——它们是片名的一部分（`最終楽章 前編`）。
final RegExp _discVolumeMarker = RegExp(
  r'[\s　._-]*(?:([上中下])[巻卷]|第?\s*(\d{1,2})\s*[巻卷]|'
  r'(?:Vol(?:ume)?\.?|Disc|Disk|BD|DVD)[\s._-]*(\d{1,2}))$',
  caseSensitive: false,
);

/// 只说明「这是第几张盘 / 什么介质」、不带作品名的目录名：`Disc 1` `BD` `BDROM`
/// `DVD2` `Vol.3` `上巻`。纯数字目录不算（目录 `86` 是番名）。
final RegExp _genericDiscDirectory = RegExp(
  r'^(?:(?:BD(?:MV|ROM)?|DVD|BLU-?RAY|UHD|DISC|DISK|VOL(?:UME)?\.?)'
  r'[\s._-]*\d{0,3}|[上中下][巻卷]|第?\d{1,3}[巻卷])$',
  caseSensitive: false,
);

/// 去掉盘名尾部的卷标（`魔女の旅々　上巻` → `魔女の旅々`）；整个名字就是卷标时
/// 原样返回，不给出空标题。
String stripDiscVolumeMarker(String name) {
  final String trimmed = name.trim();
  final String stripped = trimmed.replaceFirst(_discVolumeMarker, '').trim();
  return stripped.isEmpty ? trimmed : stripped;
}

/// [name] 是不是只有卷标 / 介质名、不带作品名的目录名。
bool isGenericDiscDirectoryName(String name) =>
    _genericDiscDirectory.hasMatch(name.trim());

/// [name] 尾部卷标说的是第几卷：`上/中/下` = 1/2/3，其余取数字；没有卷标返回 null。
int? discVolumeNumber(String name) {
  final Match? match = _discVolumeMarker.firstMatch(name.trim());
  if (match == null) return null;
  final String? kanji = match.group(1);
  if (kanji != null) return const <String, int>{'上': 1, '中': 2, '下': 3}[kanji];
  return int.tryParse(match.group(2) ?? match.group(3) ?? '');
}

/// 一组要并成一个合集的盘。
class BlurayReleaseSet {
  const BlurayReleaseSet({
    required this.name,
    required this.parentPath,
    required this.discs,
    required this.episodic,
  });

  /// 合集名的首选：剧集组是去卷标的作品名，否则就是盘名。
  final String name;

  /// 这组盘共同的上级目录（发布目录）。
  final String parentPath;

  /// 组内的盘，按盘序。非剧集组恒为一张。
  final List<BlurayDisc> discs;

  /// 是不是按集展开的剧集组（成员跨盘按集排、对齐按完整路径）。
  final bool episodic;
}

/// 去掉卷标后的作品名：盘名来自盘内 META 时取盘名；盘名就是目录名时，目录名只是
/// 卷标（`Disc 1`）就取上级目录名，否则取去卷标后的目录名。
String blurayReleaseStem(BlurayDisc disc) {
  final String root = p.normalize(disc.rootPath);
  final String directory = p.basename(root);
  if (disc.name != directory) return stripDiscVolumeMarker(disc.name);
  if (isGenericDiscDirectoryName(directory)) {
    final String parent = p.basename(p.dirname(root));
    return parent.isEmpty ? directory : parent;
  }
  return stripDiscVolumeMarker(directory);
}

/// 没有卷标的盘排在有卷标的之后。
const int kDiscVolumeUnknown = 1 << 20;

/// [disc] 的卷号（先看盘名再看目录名）；都没有卷标返回 [kDiscVolumeUnknown]。
int blurayDiscVolumeOrder(BlurayDisc disc) =>
    discVolumeNumber(disc.name) ?? discDirectoryVolumeOrder(disc.rootPath);

/// 只凭盘根目录名看卷号（盘本轮没读到、拿不到盘内标题时用）。
int discDirectoryVolumeOrder(String discRootPath) =>
    discVolumeNumber(p.basename(p.normalize(discRootPath))) ??
    kDiscVolumeUnknown;

/// 同一组内的盘序：卷号（先看盘名再看目录名），再按路径自然序。
int compareBlurayDiscOrder(BlurayDisc a, BlurayDisc b) {
  final int byVolume = blurayDiscVolumeOrder(
    a,
  ).compareTo(blurayDiscVolumeOrder(b));
  if (byVolume != 0) return byVolume;
  return naturalCompare(a.rootPath, b.rootPath);
}

/// 把一批读好的盘分组。剧集盘（有按集展开的标题）按「上级目录 + 作品名」并组，
/// 其余一张一组；组的先后按各组第一张盘在 [discs] 里的位置。
List<BlurayReleaseSet> planBlurayReleaseSets(List<BlurayDisc> discs) {
  final Map<String, List<BlurayDisc>> episodic = <String, List<BlurayDisc>>{};
  final List<Object> order = <Object>[];
  for (final BlurayDisc disc in discs) {
    if (!disc.titles.any((BlurayTitle title) => title.isEpisode)) {
      order.add(disc);
      continue;
    }
    final String parent = p.dirname(p.normalize(disc.rootPath));
    final String key = '$parent\n${blurayReleaseStem(disc)}';
    final List<BlurayDisc>? group = episodic[key];
    if (group == null) {
      episodic[key] = <BlurayDisc>[disc];
      order.add(key);
    } else {
      group.add(disc);
    }
  }
  return <BlurayReleaseSet>[
    for (final Object entry in order)
      if (entry is BlurayDisc)
        BlurayReleaseSet(
          name: entry.name,
          parentPath: p.dirname(p.normalize(entry.rootPath)),
          discs: <BlurayDisc>[entry],
          episodic: false,
        )
      else
        BlurayReleaseSet(
          name: blurayReleaseStem(episodic[entry]!.first),
          parentPath: p.dirname(p.normalize(episodic[entry]!.first.rootPath)),
          discs: List<BlurayDisc>.unmodifiable(
            List<BlurayDisc>.of(episodic[entry]!)..sort(compareBlurayDiscOrder),
          ),
          episodic: true,
        ),
  ];
}
