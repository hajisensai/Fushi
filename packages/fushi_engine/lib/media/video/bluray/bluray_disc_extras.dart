import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;

/// 不属于正片集合、且短于正片集合里最短一条这个比例的标题，是这张盘的特典。
///
/// 基准是「正片集合」而不是「最长那条」（PR #2058 审查）：剧集盘上一条 50 分钟的
/// 特别篇会让 24 分钟的各集全部低于「最长者的一半」，被当成特典不刮；漏网的「全部
/// 播放」当锚时同样。正片集合的认法见 [classifyBlurayDiscExtras]。
const double kBlurayExtraRelativeDuration = 0.5;

/// 一组标题算「时长相近的一组剧集」的条件：组内最长不超过最短的这个倍数。
///
/// 同一部剧各集通常只差几十秒（23:40 对 24:10，约 1.02），1.2 留出 OP/ED 省略、
/// 总集篇略长之类的余量。
const double kBlurayEpisodeDurationSpread = 1.2;

/// 候选的剧集组要成为正片集合，组内总时长至少是最长单条正片级标题的这个比例。
///
/// 这一条把「电影 + 两条长度相近的制作特辑」（143 分钟对 31 + 28 分钟，41%）与
/// 「几集正片 + 一条特别篇」（4 × 24 分钟对 50 分钟，192%）分开。拿不准时偏向「不是
/// 特典」：误判成剧集的代价是特辑照旧各自刮削，误判成特典的代价是正片不刮。
const double kBlurayEpisodeGroupWeight = 0.75;

/// 盘上有「全部播放」把这组标题串起来时的门槛：作者亲手声明了「这几条是连着看的
/// 一组」，比单凭时长相近可靠，门槛放低（2 集 24 分钟 + 70 分钟特别篇 = 69% 仍算
/// 剧集组）；电影盘「全部特典连播」的两条特辑对正片通常远不到一半。
const double kBlurayPlayAllGroupWeight = 0.5;

/// 一张盘的特典划分（纯结构判据的结论）。
class BlurayDiscExtrasPlan {
  const BlurayDiscExtrasPlan({
    required this.extraIds,
    required this.parentOrder,
    required this.durationTicks,
  });

  /// 特典的 MPLS 号：没被选成标题的播放列表（菜单特典、厂标、play-all、章节子集
  /// ……只要它进了库就只能是附属内容），加上正片集合之外、远短于正片的标题。
  final Set<String> extraIds;

  /// 特典的父标题候选（MPLS 号），按优先级：正片集合（按编号）→ 其余正片级
  /// 标题（按编号）→ play-all 形状的标题。
  final List<String> parentOrder;

  /// 每条播放列表的时长（45kHz ticks），挑兜底父项用。
  final Map<String, int> durationTicks;
}

/// 从盘的结构认出正片集合，再据此划出特典。纯函数。
///
/// 正片集合按这个顺序认：
/// 1. 去掉 play-all 形状的标题（片段集合严格包住另外 ≥ 2 条标题）——它们不当基准；
/// 2. 候选组：盘上任意一条播放列表（含没选成标题的 play-all）串起来的 ≥ 2 条标题，
///    以及时长相近（[kBlurayEpisodeDurationSpread]）的 ≥ 2 条标题；
/// 3. 总时长 ≥ 最长正片级标题 × 门槛（play-all 串起来的组 [kBlurayPlayAllGroupWeight]，
///    仅时长相近的组 [kBlurayEpisodeGroupWeight]）的候选组里取总时长最大的那组当
///    正片集合（剧集盘）；没有就取最长的那条（电影盘）。
///
/// 正片集合之外、短于集合里最短一条 × [kBlurayExtraRelativeDuration] 的标题是特典；
/// 比它长的（剧集盘的特别篇、总集篇）照旧是正片。
BlurayDiscExtrasPlan classifyBlurayDiscExtras(BlurayDisc disc) {
  final List<BlurayPlaylist> titles = <BlurayPlaylist>[
    for (final BlurayTitle title in disc.titles) title.playlist,
  ];
  final Set<String> titleIds = <String>{
    for (final BlurayPlaylist t in titles) t.id,
  };
  final List<BlurayPlaylist> playAll = <BlurayPlaylist>[];
  List<BlurayPlaylist> features = <BlurayPlaylist>[];
  for (final BlurayPlaylist t in titles) {
    if (_coveredTitles(t, titles).length >= 2) {
      playAll.add(t);
    } else {
      features.add(t);
    }
  }
  if (features.isEmpty) {
    features = List<BlurayPlaylist>.of(titles);
    playAll.clear();
  }

  final Set<String> extras = <String>{
    for (final BlurayPlaylist playlist in disc.playlists)
      if (!titleIds.contains(playlist.id)) playlist.id,
  };
  final Map<String, int> durations = <String, int>{
    for (final BlurayPlaylist playlist in disc.playlists)
      playlist.id: playlist.durationTicks,
  };
  if (features.isEmpty) {
    return BlurayDiscExtrasPlan(
      extraIds: extras,
      parentOrder: const <String>[],
      durationTicks: durations,
    );
  }

  int longest = 0;
  BlurayPlaylist longestFeature = features.first;
  for (final BlurayPlaylist f in features) {
    if (f.durationTicks > longest) {
      longest = f.durationTicks;
      longestFeature = f;
    }
  }

  final List<({List<BlurayPlaylist> members, double weight})> groups =
      <({List<BlurayPlaylist> members, double weight})>[];
  for (final BlurayPlaylist playlist in disc.playlists) {
    final List<BlurayPlaylist> covered = _coveredTitles(playlist, features);
    if (covered.length >= 2) {
      groups.add((members: covered, weight: kBlurayPlayAllGroupWeight));
    }
  }
  final List<BlurayPlaylist> byDuration = List<BlurayPlaylist>.of(features)
    ..sort(
      (BlurayPlaylist a, BlurayPlaylist b) =>
          a.durationTicks.compareTo(b.durationTicks),
    );
  for (int i = 0; i < byDuration.length; i++) {
    final double ceiling =
        byDuration[i].durationTicks * kBlurayEpisodeDurationSpread;
    int end = i;
    while (end < byDuration.length &&
        byDuration[end].durationTicks <= ceiling) {
      end++;
    }
    if (end - i >= 2) {
      groups.add((
        members: byDuration.sublist(i, end),
        weight: kBlurayEpisodeGroupWeight,
      ));
    }
  }

  List<BlurayPlaylist> core = <BlurayPlaylist>[longestFeature];
  int coreTotal = 0;
  for (final ({List<BlurayPlaylist> members, double weight}) group in groups) {
    final int total = group.members.fold<int>(
      0,
      (int sum, BlurayPlaylist t) => sum + t.durationTicks,
    );
    if (total < longest * group.weight) continue;
    if (total > coreTotal) {
      core = group.members;
      coreTotal = total;
    }
  }

  final Set<String> coreIds = <String>{
    for (final BlurayPlaylist t in core) t.id,
  };
  final int reference = core
      .map((BlurayPlaylist t) => t.durationTicks)
      .reduce((int a, int b) => a < b ? a : b);
  final double floor = reference * kBlurayExtraRelativeDuration;
  for (final BlurayPlaylist f in features) {
    if (!coreIds.contains(f.id) && f.durationTicks < floor) extras.add(f.id);
  }

  int byId(String a, String b) => a.compareTo(b);
  return BlurayDiscExtrasPlan(
    extraIds: extras,
    parentOrder: <String>[
      ...(coreIds.toList()..sort(byId)),
      ...(<String>[
        for (final BlurayPlaylist f in features)
          if (!coreIds.contains(f.id) && !extras.contains(f.id)) f.id,
      ]..sort(byId)),
      ...(<String>[for (final BlurayPlaylist t in playAll) t.id]..sort(byId)),
    ],
    durationTicks: durations,
  );
}

/// [disc] 上哪些播放列表是特典（MPLS 号），见 [classifyBlurayDiscExtras]。
Set<String> blurayExtraPlaylistIds(BlurayDisc disc) =>
    classifyBlurayDiscExtras(disc).extraIds;

/// [pool] 里片段集合被 [playlist] 完整包住的其它标题。
List<BlurayPlaylist> _coveredTitles(
  BlurayPlaylist playlist,
  List<BlurayPlaylist> pool,
) {
  final Set<String> own = playlist.clipIds.toSet();
  return <BlurayPlaylist>[
    for (final BlurayPlaylist other in pool)
      if (other.id != playlist.id &&
          other.clipIds.isNotEmpty &&
          other.clipIds.toSet().length < own.length &&
          own.containsAll(other.clipIds))
        other,
  ];
}

/// [videoPaths] 里属于蓝光盘特典的那些：归一路径 → 它挂靠的同盘父标题 `.mpls` 路径。
///
/// 特典不按自己的标题去识别——盘名就是正片的片名，拿它去搜只会把 31 分钟的特辑
/// 认成整部电影。它们与 NCOP / 预告同样处理：不进刮削计划，挂到父标题的作品下当附件。
///
/// 父标题只在 [videoPaths] 里找（调用方传的是一个来源的全部行，计划器与索引器传同
/// 一批，两边结论一致）：先按 [BlurayDiscExtrasPlan.parentOrder]，再退到任一在库的
/// 正片级标题。**正片一条都不在库**（用户删了正片、或只导入了特典）时，在库特典里
/// 最长的那条顶上：它不进本映射、照常进计划被刮削，同盘其余特典挂到它下面——整盘
/// 仍归成一个作品，而不是一堆既刮不到、又挂不上的孤行（PR #2058 审查）。
Future<Map<String, String>> blurayDiscExtras(
  Iterable<String> videoPaths,
) async {
  final Map<String, List<String>> byRoot = <String, List<String>>{};
  final Map<String, String> rootPath = <String, String>{};
  for (final String path in videoPaths) {
    if (!isBlurayPlaylistPath(path)) continue;
    final String? root = blurayDiscRootForPlaylistPath(path);
    if (root == null) continue;
    final String key = normalizeVideoPath(root);
    rootPath.putIfAbsent(key, () => root);
    byRoot.putIfAbsent(key, () => <String>[]).add(path);
  }
  final Map<String, String> result = <String, String>{};
  for (final MapEntry<String, List<String>> entry in byRoot.entries) {
    final BlurayDiscExtrasPlan? plan = await _planForDisc(rootPath[entry.key]!);
    if (plan == null) continue;
    final Map<String, String> pathById = <String, String>{
      for (final String path in entry.value)
        p.basenameWithoutExtension(path): path,
    };
    final List<String> presentExtras = <String>[
      for (final String id in pathById.keys)
        if (plan.extraIds.contains(id)) id,
    ]..sort();
    if (presentExtras.isEmpty) continue;
    String? parent;
    for (final String id in plan.parentOrder) {
      if (pathById.containsKey(id)) {
        parent = id;
        break;
      }
    }
    if (parent == null) {
      final List<String> others = <String>[
        for (final String id in pathById.keys)
          if (!plan.extraIds.contains(id)) id,
      ]..sort();
      if (others.isNotEmpty) parent = others.first;
    }
    if (parent == null) {
      parent = presentExtras.first;
      for (final String id in presentExtras) {
        if ((plan.durationTicks[id] ?? 0) > (plan.durationTicks[parent] ?? 0)) {
          parent = id;
        }
      }
    }
    final String parentPath = pathById[parent]!;
    for (final String id in presentExtras) {
      if (id == parent) continue;
      result[normalizeVideoPath(pathById[id]!)] = parentPath;
    }
  }
  return result;
}

/// 盘 → 特典划分的进程内缓存（PR #2058 审查：刮削规划、索引、扫描清扫在一次启动里
/// 对同一个来源要规划好几遍，每遍都重读、重解析整盘 MPLS）。
///
/// 失效判据是 `PLAYLIST/` 下每个 `.mpls` 的大小与修改时间，加 `STREAM/` 目录的修改
/// 时间（片段增删会改它，「片段是否齐全」参与标题筛选）：stat 比读 + 解析便宜，且换
/// 盘 / 改盘一定会变。读不了目录时不缓存，照旧现读。
final Map<String, ({String fingerprint, BlurayDiscExtrasPlan? plan})>
_planCache = <String, ({String fingerprint, BlurayDiscExtrasPlan? plan})>{};

const int _kPlanCacheLimit = 256;

Future<BlurayDiscExtrasPlan?> _planForDisc(String root) async {
  final String key = normalizeVideoPath(root);
  final String? fingerprint = _discFingerprint(root);
  final ({String fingerprint, BlurayDiscExtrasPlan? plan})? cached =
      _planCache[key];
  if (fingerprint != null &&
      cached != null &&
      cached.fingerprint == fingerprint) {
    return cached.plan;
  }
  final BlurayDisc? disc = await readBlurayDisc(root);
  final BlurayDiscExtrasPlan? plan = disc == null
      ? null
      : classifyBlurayDiscExtras(disc);
  if (fingerprint != null) {
    _planCache.remove(key);
    if (_planCache.length >= _kPlanCacheLimit) {
      _planCache.remove(_planCache.keys.first);
    }
    _planCache[key] = (fingerprint: fingerprint, plan: plan);
  }
  return plan;
}

String? _discFingerprint(String root) {
  try {
    final List<FileSystemEntity> entries =
        Directory(p.join(root, 'BDMV', 'PLAYLIST')).listSync(followLinks: false)
          ..sort((FileSystemEntity a, FileSystemEntity b) {
            return a.path.compareTo(b.path);
          });
    final StringBuffer buffer = StringBuffer();
    for (final FileSystemEntity entity in entries) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() != '.mpls') continue;
      final FileStat stat = entity.statSync();
      buffer
        ..write(p.basename(entity.path))
        ..write(':')
        ..write(stat.size)
        ..write(':')
        ..write(stat.modified.microsecondsSinceEpoch)
        ..write(';');
    }
    final FileStat stream = FileStat.statSync(p.join(root, 'BDMV', 'STREAM'));
    buffer
      ..write('S:')
      ..write(stream.type)
      ..write(':')
      ..write(stream.modified.microsecondsSinceEpoch);
    return buffer.toString();
  } on FileSystemException {
    return null;
  }
}

/// 测试用：清空 [blurayDiscExtras] 的盘缓存。
void debugClearBlurayDiscExtrasCache() => _planCache.clear();
