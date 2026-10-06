/// online 域控制通道路由的纯函数与进程内小账本（与 UI / AppModel 无关，便于单测）。
///
/// - [OnlineCtlKind]：`--kind manga|anime|novel` 的解析；
/// - [parseCtlIndexRanges]：`--chapters 1-10,15,20-` 的解析；
/// - [CtlOnlineTaskRegistry]：CLI 发起、没有现成下载中心承载的长任务（LNReader 整本下载）；
/// - [CtlDiscoveryResultCache]：`discover search` 的结果按短 id 暂存，供 `discover get` 取回；
/// - [homeTabFromCtlName] / [kCtlNavigationNames]：`nav go <页面>` 的名字表；
/// - [resolveCtlPlaybackTarget]：`play --target video|audiobook` 的选择。
library;

import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;

import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/home_tab.dart';

/// 在线扩展 / 在线源的内容域。
enum OnlineCtlKind {
  /// Mihon 漫画扩展（`appModel.mihonManager`）。
  manga,

  /// Aniyomi 视频扩展（`appModel.animeMihonManager`）。
  anime,

  /// LNReader 小说插件（`appModel.lnReaderManager`）。
  novel;

  /// `manga` / `anime`（别名 `video`）/ `novel`（别名 `book`）；缺省按 [fallback]。
  static OnlineCtlKind parse(String? raw, {OnlineCtlKind? fallback}) {
    final String value = (raw ?? '').trim().toLowerCase();
    switch (value) {
      case 'manga' || 'comic':
        return OnlineCtlKind.manga;
      case 'anime' || 'video':
        return OnlineCtlKind.anime;
      case 'novel' || 'book' || 'books':
        return OnlineCtlKind.novel;
      case '':
        if (fallback != null) return fallback;
        throw const CtlFailure.badRequest('kind 缺失（manga | anime | novel）');
    }
    throw CtlFailure.badRequest('未知 kind：$raw（manga | anime | novel）');
  }
}

/// 解析 1 起的序号范围（`1-10,15,20-`），返回去重升序的 0 起下标。
///
/// [total] 是可选项总数：`20-` 表示 20 到末尾；越界的序号抛 400，而不是静默丢掉——
/// 「我要 1-10 章」被悄悄截成 1-8 章比报错更糟。null / 空串 = 全部。
List<int> parseCtlIndexRanges(String? spec, int total) {
  final String text = (spec ?? '').trim();
  if (text.isEmpty || text == 'all' || text == '*') {
    return List<int>.generate(total, (int i) => i);
  }
  final Set<int> picked = <int>{};
  for (final String part in text.split(',')) {
    final String token = part.trim();
    if (token.isEmpty) continue;
    final RegExpMatch? match = RegExp(
      r'^(\d+)?\s*(-)?\s*(\d+)?$',
    ).firstMatch(token);
    if (match == null || (match.group(1) == null && match.group(3) == null)) {
      throw CtlFailure.badRequest('无法解析范围：$token');
    }
    final bool isRange = match.group(2) != null;
    final int start = int.tryParse(match.group(1) ?? '') ?? 1;
    final int end = isRange
        ? int.tryParse(match.group(3) ?? '') ?? total
        : start;
    if (!isRange && match.group(3) != null) {
      throw CtlFailure.badRequest('无法解析范围：$token');
    }
    if (start < 1 || end < start || end > total) {
      throw CtlFailure.badRequest('范围 $token 越界（共 $total 项）');
    }
    for (int i = start; i <= end; i++) {
      picked.add(i - 1);
    }
  }
  if (picked.isEmpty) throw CtlFailure.badRequest('范围为空：$text');
  return picked.toList()..sort();
}

/// 一个 CLI 发起的后台任务的快照。
class CtlOnlineTask {
  CtlOnlineTask({
    required this.id,
    required this.kind,
    required this.title,
    required this.total,
    required this.createdAt,
  });

  final String id;
  final String kind;
  final String title;
  final int total;
  final int createdAt;

  /// `running` / `done` / `failed` / `cancelled`。
  String status = 'running';
  int done = 0;
  String? error;

  /// 完成后的产物（如入库书的 bookKey）。
  String? resultKey;
  int? finishedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'title': title,
    'status': status,
    'done': done,
    'total': total,
    if (error != null) 'error': error,
    if (resultKey != null) 'resultKey': resultKey,
    'createdAt': createdAt,
    if (finishedAt != null) 'finishedAt': finishedAt,
  };
}

/// CLI 发起的长任务账本（进程内，app 重启即清空）。
///
/// 只承载**没有现成下载中心**的任务：漫画章节进漫画下载队列、视频剧集进 app 级
/// 下载管理器，那两类在各自的下载中心里可见可控，不在这里重复登记。
class CtlOnlineTaskRegistry {
  CtlOnlineTaskRegistry({int Function()? clock, this.maxFinished = 50})
    : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static final CtlOnlineTaskRegistry instance = CtlOnlineTaskRegistry();

  final int Function() _clock;

  /// 保留的已结束任务条数上限（运行中的不计、不淘汰）。
  final int maxFinished;
  final List<CtlOnlineTask> _tasks = <CtlOnlineTask>[];
  int _next = 0;

  List<CtlOnlineTask> get tasks => List<CtlOnlineTask>.unmodifiable(_tasks);

  CtlOnlineTask? byId(String id) {
    for (final CtlOnlineTask task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  CtlOnlineTask start({
    required String kind,
    required String title,
    required int total,
  }) {
    final CtlOnlineTask task = CtlOnlineTask(
      id: 't${++_next}',
      kind: kind,
      title: title,
      total: total,
      createdAt: _clock(),
    );
    _tasks.add(task);
    _trim();
    return task;
  }

  void finish(
    CtlOnlineTask task, {
    required String status,
    String? error,
    String? resultKey,
  }) {
    task
      ..status = status
      ..error = error
      ..resultKey = resultKey
      ..finishedAt = _clock();
    _trim();
  }

  void _trim() {
    final List<CtlOnlineTask> finished = _tasks
        .where((CtlOnlineTask t) => t.status != 'running')
        .toList();
    final int excess = finished.length - maxFinished;
    if (excess <= 0) return;
    for (final CtlOnlineTask task in finished.take(excess)) {
      _tasks.remove(task);
    }
  }
}

/// `discover search` 的结果按短 id（`r1`、`r2`…）暂存，`discover get <id>` 取回原对象。
///
/// 发现条目没有跨进程稳定的短身份（源内 id 常是整条 URL），而下载必须拿到搜索时
/// 的原对象（带已物化的 payload），所以由 app 进程持有、按 LRU 保留最近 [capacity] 条。
class CtlDiscoveryResultCache<T> {
  CtlDiscoveryResultCache({this.capacity = 500});

  final int capacity;
  final Map<String, T> _byId = <String, T>{};
  int _next = 0;

  String put(T value) {
    final String id = 'r${++_next}';
    _byId[id] = value;
    while (_byId.length > capacity) {
      _byId.remove(_byId.keys.first);
    }
    return id;
  }

  T? operator [](String id) => _byId[id];

  int get length => _byId.length;
}

/// `nav go` 接受的页面名 → 顶层页签（含别名）。
const Map<String, HomeTab> kCtlNavigationNames = <String, HomeTab>{
  'home': HomeTab.home,
  'dashboard': HomeTab.home,
  'books': HomeTab.books,
  'book': HomeTab.books,
  'library': HomeTab.books,
  'manga': HomeTab.manga,
  'video': HomeTab.video,
  'videos': HomeTab.video,
  'games': HomeTab.games,
  'game': HomeTab.games,
  'browse': HomeTab.browse,
  'downloads': HomeTab.browse,
  'dictionaries': HomeTab.dictionaries,
  'dictionary': HomeTab.dictionaries,
  'dict': HomeTab.dictionaries,
  'lookup': HomeTab.dictionaries,
  'browser-extension': HomeTab.browserExtension,
  'extension': HomeTab.browserExtension,
  'settings': HomeTab.settings,
};

/// 页签的规范名（[kCtlNavigationNames] 里与枚举同名或首选的那个）。
String ctlNavigationName(HomeTab tab) => switch (tab) {
  HomeTab.home => 'home',
  HomeTab.books => 'books',
  HomeTab.manga => 'manga',
  HomeTab.video => 'video',
  HomeTab.browse => 'browse',
  HomeTab.dictionaries => 'dictionaries',
  HomeTab.games => 'games',
  HomeTab.browserExtension => 'browser-extension',
  HomeTab.settings => 'settings',
};

/// 解析 `nav go` 的页面名；未知名抛 400 并列出可用名。
HomeTab homeTabFromCtlName(String raw) {
  final HomeTab? tab = kCtlNavigationNames[raw.trim().toLowerCase()];
  if (tab == null) {
    throw CtlFailure.badRequest(
      '未知页面：$raw（可用：${HomeTab.values.map(ctlNavigationName).join(' / ')}）',
    );
  }
  return tab;
}

/// `play` 命令遥控的播放器种类。
enum CtlPlaybackTarget {
  /// 视频播放页（`videoPlaybackRemotes` 登记的最上层那页）。
  video,

  /// 进程级有声书会话（`AppModel.audiobookSession`）。
  audiobook,
}

/// 选出 `play` 要控制的播放器：
///
/// - [requested] 为 `video` / `audiobook` 时照办（不管那边在不在，由调用方报「没有」）；
/// - 缺省 / `auto`：有视频页登记（[hasVideo]，视频页开着就盖在有声书之上）→ 视频；
///   否则有有声书会话 → 有声书；都没有 → null。
///
/// 未知取值抛 [CtlFailure.badRequest]。
CtlPlaybackTarget? resolveCtlPlaybackTarget({
  required String? requested,
  required bool hasVideo,
  required bool hasAudiobook,
}) {
  final String value = (requested ?? '').trim().toLowerCase();
  switch (value) {
    case '' || 'auto':
      if (hasVideo) return CtlPlaybackTarget.video;
      if (hasAudiobook) return CtlPlaybackTarget.audiobook;
      return null;
    case 'video':
      return CtlPlaybackTarget.video;
    case 'audiobook' || 'audio':
      return CtlPlaybackTarget.audiobook;
    default:
      throw CtlFailure.badRequest('未知 target：$requested（video | audiobook）');
  }
}

/// 视频页遥控状态的应答形状（与有声书那份同字段，`kind: video`，身份键是 `bookUid`）。
/// [snapshot] 为 null = 视频页已打开但控制器还没就绪（`ready: false`）。
Map<String, Object?> ctlVideoPlaybackJson(VideoPlaybackSnapshot? snapshot) {
  if (snapshot == null) {
    return <String, Object?>{'active': true, 'kind': 'video', 'ready': false};
  }
  return <String, Object?>{
    'active': true,
    'kind': 'video',
    'ready': true,
    'bookUid': snapshot.bookUid,
    'title': snapshot.title,
    'playing': snapshot.playing,
    'positionMs': snapshot.positionMs,
    'durationMs': snapshot.durationMs,
    'speed': snapshot.speed,
    'cue': snapshot.cue,
  };
}
