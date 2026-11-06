/// 视频来源里扫到的纯音频交给音乐库时，该登记哪些音乐来源（反馈 QAondMh4M5）。
///
/// 纯函数，不碰文件系统：调用方给出视频来源根、本次扫到的纯音频文件、视频库认领的
/// 媒体所在目录（视频文件 / 播放列表 / 原盘根）和已有的本地音乐来源，这里只算路径。
///
/// 规则（每个纯音频文件所在目录 A）：
/// 1. **已覆盖**：某个音乐来源根 = A，或某个递归音乐来源根包含 A → 不再登记（音乐来源
///    自己的扫描会收它，不重复入库）。
/// 2. **与视频同目录**：A 直接装着视频库媒体 → 不收。这类音频几乎都是那集视频的外挂
///    音轨 / 评论音轨（`ep01.mkv` 旁的 `ep01.flac`），不是专辑；而且音乐扫描认 `.mp4`，
///    在这样的目录登记音乐来源会把旁边的视频当曲目收进去。
/// 3. **视频在子目录**：A 本身没有视频、但子树里有（`Show/op.flac` + `Show/S1/ep01.mkv`）
///    → 登记 A，**不递归**：只收 A 下面的音频，不下钻到视频目录（递归来源还会把子树
///    里的 BD / DVD 原盘登记成音乐专辑）。
/// 4. 否则从 A 往上爬，直到再往上一层就会碰到视频媒体 / 已有音乐来源、或到了视频来源根
///    → 登记爬到的那一层，**递归**。BD 整包 `Show/CDs/<14 张专辑>/` 由此得到一个
///    `Show/CDs` 来源，而不是 14 个。
///
/// 已有音乐来源根落在视频来源根内时，同样当作「往上爬的边界」：新来源不会包住一个
/// 已有来源（两个来源重叠时同一首曲目会在两次扫描间来回换 `sourceId`）。
library;

import 'package:fushi_core/fushi_core.dart' show musicTrackPathKey;
import 'package:path/path.dart' as p;

/// 一个已有的本地音乐来源（只要根与是否递归）。
typedef MusicSourceRoot = ({String rootPath, bool recursive});

/// 一个要新登记的音乐来源。
typedef PlannedMusicRoot = ({String rootPath, bool recursive});

/// [planMusicRootsForVideoSourceAudio] 的结果。
class MusicAudioRootPlan {
  const MusicAudioRootPlan({
    required this.roots,
    required this.coveredAudioPaths,
    required this.besideVideoAudioPaths,
  });

  /// 要新登记的音乐来源（按路径排序，去重，互不包含）。
  final List<PlannedMusicRoot> roots;

  /// 已被现有音乐来源覆盖的音频（不再登记）。
  final List<String> coveredAudioPaths;

  /// 与视频同目录、不收的音频（规则 2）。
  final List<String> besideVideoAudioPaths;
}

/// 见文件头。[context] 默认宿主平台的 `path` 语义（Windows 大小写不敏感）。
MusicAudioRootPlan planMusicRootsForVideoSourceAudio({
  required String videoRoot,
  required Iterable<String> audioPaths,
  required Iterable<String> videoMediaDirs,
  required Iterable<MusicSourceRoot> musicSources,
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  String key(String path) => musicTrackPathKey(path, context: ctx);
  bool inOrAt(String root, String path) =>
      ctx.equals(root, path) || ctx.isWithin(root, path);

  final String root = ctx.normalize(videoRoot);
  final List<MusicSourceRoot> sources = <MusicSourceRoot>[
    for (final MusicSourceRoot s in musicSources)
      (rootPath: ctx.normalize(s.rootPath), recursive: s.recursive),
  ];

  // 直接装着视频库媒体的目录，以及它们在视频来源根内的全部祖先（含自身）。
  final Set<String> directVideoDirs = <String>{};
  final Set<String> blockers = <String>{};
  void addChain(String dir) {
    String d = ctx.normalize(dir);
    if (!inOrAt(root, d)) return;
    while (true) {
      if (!blockers.add(key(d))) return; // 往上的祖先已经登记过
      if (ctx.equals(d, root)) return;
      d = ctx.dirname(d);
    }
  }

  for (final String dir in videoMediaDirs) {
    if (inOrAt(root, dir)) directVideoDirs.add(key(dir));
    addChain(dir);
  }
  for (final MusicSourceRoot s in sources) {
    addChain(s.rootPath);
  }

  bool covered(String dir) => sources.any(
    (MusicSourceRoot s) =>
        ctx.equals(s.rootPath, dir) ||
        (s.recursive && ctx.isWithin(s.rootPath, dir)),
  );

  final List<String> coveredAudio = <String>[];
  final List<String> besideVideo = <String>[];
  final Map<String, PlannedMusicRoot> planned = <String, PlannedMusicRoot>{};
  for (final String audio in audioPaths) {
    final String dir = ctx.dirname(ctx.normalize(audio));
    if (covered(dir)) {
      coveredAudio.add(audio);
      continue;
    }
    if (directVideoDirs.contains(key(dir))) {
      besideVideo.add(audio);
      continue;
    }
    if (blockers.contains(key(dir))) {
      planned.putIfAbsent(key(dir), () => (rootPath: dir, recursive: false));
      continue;
    }
    String top = dir;
    while (!ctx.equals(top, root) && inOrAt(root, ctx.dirname(top))) {
      final String parent = ctx.dirname(top);
      if (blockers.contains(key(parent))) break;
      top = parent;
    }
    // top 不在 blockers 里，与上面的非递归计划（目录必在 blockers 里）不会同键。
    planned.putIfAbsent(key(top), () => (rootPath: top, recursive: true));
  }
  // 递归计划互不包含（各自是「再往上就碰边界」的最高层）；非递归计划所在目录必在
  // blockers 里，不会落进任何递归计划的子树。这里只按路径排序给出稳定顺序。
  final List<PlannedMusicRoot> roots = planned.values.toList()
    ..sort(
      (PlannedMusicRoot a, PlannedMusicRoot b) =>
          key(a.rootPath).compareTo(key(b.rootPath)),
    );
  return MusicAudioRootPlan(
    roots: roots,
    coveredAudioPaths: coveredAudio,
    besideVideoAudioPaths: besideVideo,
  );
}

/// 视频来源自动登记过的一个音乐来源。
typedef OwnedMusicRoot = ({int id, String rootPath, bool recursive});

/// 为什么撤掉一个自动登记的音乐来源（[ownedMusicRootsToRetire]）。
enum OwnedMusicRootRetireReason {
  /// 不在视频来源根之下了（视频来源换了根 / 来源行被改过）。
  outsideVideoRoot,

  /// 目录已经不在了（被删除或移走）。
  missing,

  /// 目录里直接出现了视频（规则 2：再收会把视频当曲目收进去）。
  besideVideo,

  /// 递归来源的子树里出现了视频（规则 3：递归扫会把子树里的视频 / 原盘收进去）。
  /// 规划仍要这个根时已先改成不递归，走不到这里。
  videoInSubtree,

  /// 已被别的音乐来源覆盖（用户后来加了上层手动来源，或同一视频来源新登记的上层来源）。
  covered,
}

/// 视频来源扫描**完整成功**之后，它自动登记的音乐来源里哪些该撤掉（反馈 QAondMh4M5）。
///
/// 只凭正面证据撤：不能因为「这次规划里没有它」就撤——列目录不全、外接盘没挂上时那会
/// 把全部自动来源误删。证据见 [OwnedMusicRootRetireReason]；调用方保证视频来源根这次
/// 读得到（扫描成功），[dirExists] 才有资格说「目录不在了」。
///
/// [others] 是其余本地音乐来源（手动、别的视频来源登记的）；[owned] 之间互相也算覆盖
/// （自己不算）。返回 id → 原因，按 [owned] 顺序。纯函数，[context] 默认宿主平台。
Map<int, OwnedMusicRootRetireReason> ownedMusicRootsToRetire({
  required String videoRoot,
  required Iterable<OwnedMusicRoot> owned,
  required Iterable<MusicSourceRoot> others,
  required Iterable<String> videoMediaDirs,
  required bool Function(String dir) dirExists,
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  String key(String path) => musicTrackPathKey(path, context: ctx);
  final String root = ctx.normalize(videoRoot);
  final Set<String> videoDirs = <String>{
    for (final String d in videoMediaDirs) key(ctx.normalize(d)),
  };
  final List<OwnedMusicRoot> mine = owned.toList();
  final List<({String rootPath, bool recursive, int? id})>
  covers = <({String rootPath, bool recursive, int? id})>[
    for (final MusicSourceRoot s in others)
      (rootPath: ctx.normalize(s.rootPath), recursive: s.recursive, id: null),
    for (final OwnedMusicRoot s in mine)
      (rootPath: ctx.normalize(s.rootPath), recursive: s.recursive, id: s.id),
  ];
  final Map<int, OwnedMusicRootRetireReason> out =
      <int, OwnedMusicRootRetireReason>{};
  for (final OwnedMusicRoot s in mine) {
    final String dir = ctx.normalize(s.rootPath);
    if (!ctx.equals(root, dir) && !ctx.isWithin(root, dir)) {
      out[s.id] = OwnedMusicRootRetireReason.outsideVideoRoot;
    } else if (!dirExists(s.rootPath)) {
      out[s.id] = OwnedMusicRootRetireReason.missing;
    } else if (videoDirs.contains(key(dir))) {
      out[s.id] = OwnedMusicRootRetireReason.besideVideo;
    } else if (s.recursive &&
        videoMediaDirs.any((String v) => ctx.isWithin(dir, ctx.normalize(v)))) {
      out[s.id] = OwnedMusicRootRetireReason.videoInSubtree;
    } else if (covers.any(
      (({String rootPath, bool recursive, int? id}) c) =>
          c.id != s.id &&
          // 已经要撤的来源不再拿来当覆盖（它的曲目不会留下）。
          !(c.id != null && out.containsKey(c.id)) &&
          ((ctx.equals(c.rootPath, dir) && c.id == null) ||
              (c.recursive && ctx.isWithin(c.rootPath, dir))),
    )) {
      out[s.id] = OwnedMusicRootRetireReason.covered;
    }
  }
  return out;
}
