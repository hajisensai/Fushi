// 媒体文件「在不在」的有界异步探测：给 UI isolate 上的播放 / 缩略图 / 字幕 / 制卡截取
// 路径用（BUG-5605）。
//
// 用户库里的视频常在网络 / 云盘挂载上（SMB、WinFsp 挂的 OpenList / rclone、NFS…）。
// 这类卷的元数据请求可以在内核里一等十几秒：同步 `File.existsSync()` 在 UI isolate 上
// 等于把整个界面冻住（实测 hang dump：主线程停在 `Builtin_File_Exists` →
// `GetTypeAndAttributes` 7～23 s）。光换成异步 `exists()` 也不够——UI 不冻了，但调用方
// 仍要干等那十几秒，而且每次重试都再压一个卡死的请求到 dart:io 的 IO 线程池上。
//
// 这里给出三态答案，把「暂时问不到」与「确实不在」分开：
//
//   - [MediaPathPresence.present]：文件在；
//   - [MediaPathPresence.missing]：卷答复了，文件不在；
//   - [MediaPathPresence.unavailable]：卷在 [kMediaPathProbeTimeout] 内没答复（或探测
//     本身出错）。调用方按「暂不可用」处理：不阻塞、不当成文件丢失、不删任何数据。
//
// 状态而不是延迟：
//
//   - 同一路径同一时刻只有一个底层 stat 在飞（[_inFlight]）；超时只是调用方不再等，
//     那个 stat 继续挂在 IO 线程上，重复探测直接复用它，不再加压。
//   - 同一卷上同时在跑的底层 stat 不超过 [kMediaProbeConcurrencyPerVolume] 个，多出来的
//     排队。异步 `exists()` 也占一条 dart:io IO 线程，rclone / WinFsp 挂载缓存未命中时
//     一个 stat 就能挂十几秒；不限并发，一阵 hover 就能把 IO 线程池占满，拖慢本机盘上
//     完全无关的文件 IO（数据库、缓存、日志）。
//   - 一个 stat 超时后，它所在的卷（[mediaVolumeKeyOf]）记为「卡住」，直到那个 stat
//     自己返回为止。期间同卷的探测立刻答 [MediaPathPresence.unavailable]，不再发新的
//     stat。卡住的 stat 一返回（不论结果），卷就恢复，[whenVolumeRecovered] 的等待方
//     被唤醒——调用方据此「恢复后再起」，而不是靠定时重试。
//
// 两个入口，按调用方意图分（审查后修正）：
//
//   - [probeMediaPath]：**推测性 / 悬停类**后台路径专用（缩略图预取、悬停取帧、起播
//     前的「文件丢失」预检）。这类结果拿不到就算了，不能让用户等，所以有界、三态。
//   - [awaitMediaPathExists]：**必达**路径专用——导入、扫描、回填、用户主动发起的片段
//     导出 / 制卡截取等。这类结果丢了就是整批静默没封面 / 元数据、或给用户报一个假的
//     「暂不可用」，所以无时限：卷卡着就等它恢复（[whenMediaVolumeRecovered]）再问，
//     永远给出真实的「在 / 不在」。同样异步、不占 UI，并共用同路径合并、同卷并发上限与
//     卡住标记，不往卡住的挂载上叠 stat。

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// 媒体路径探测的三态结果，见文件头。
enum MediaPathPresence {
  /// 文件在。
  present,

  /// 卷答复了：文件不在。
  missing,

  /// 卷没在时限内答复（网络盘卡住 / 探测出错）：暂时不知道，按「暂不可用」处理。
  unavailable,
}

/// 底层「这个路径是不是存在」的异步问法。默认 `File(path).exists()`；测试注入可阻塞
/// 的假实现（[debugOverrideMediaPathExists]）。
typedef MediaPathExistsQuery = Future<bool> Function(String path);

/// UI 路径上一次探测最多等多久。本机盘的 stat 是微秒级，健康的网络盘也在几十毫秒内；
/// 等过这个量级还没回就是卷卡住了，再等下去只是让用户对着一个不动的界面。
const Duration kMediaPathProbeTimeout = Duration(seconds: 2);

MediaPathExistsQuery _existsQuery = _defaultExists;

Future<bool> _defaultExists(String path) => File(path).exists();

/// 同一卷上同时在跑的底层 stat 上限（见文件头）。
const int kMediaProbeConcurrencyPerVolume = 2;

/// 卷键 → 正在跑的底层 stat 个数。
final Map<String, int> _volumeActive = <String, int>{};

/// 卷键 → 排队等槽位的 stat。
final Map<String, List<Completer<void>>> _volumeQueue =
    <String, List<Completer<void>>>{};

/// 排到槽位时卷已卡住：这条 stat 不再发，等待方按「暂不可用」处理。
class _VolumeStalledSkip implements Exception {
  const _VolumeStalledSkip();
}

/// 路径 → 正在飞的底层 stat。完成即移除。
final Map<String, Future<bool>> _inFlight = <String, Future<bool>>{};

/// 卷键 → 该卷上已超时、尚未返回的 stat 个数。
final Map<String, int> _stalledVolumes = <String, int>{};

/// 已经记过「卡住」的 stat（同一个 Future 只记一次）。
final Set<Future<bool>> _stalledQueries = <Future<bool>>{};

/// 卷键 → 等它恢复的调用方。
final Map<String, List<Completer<void>>> _recoveryWaiters =
    <String, List<Completer<void>>>{};

/// 测试注入：把底层 stat 换成 [query]（null = 恢复默认）。同时清空全部在飞 / 卡住状态，
/// 让每个用例从干净状态起步。
@visibleForTesting
void debugOverrideMediaPathExists(MediaPathExistsQuery? query) {
  _existsQuery = query ?? _defaultExists;
  _inFlight.clear();
  _volumeActive.clear();
  for (final List<Completer<void>> queued in _volumeQueue.values) {
    for (final Completer<void> slot in queued) {
      if (!slot.isCompleted) slot.complete();
    }
  }
  _volumeQueue.clear();
  _stalledVolumes.clear();
  _stalledQueries.clear();
  for (final List<Completer<void>> waiters in _recoveryWaiters.values) {
    for (final Completer<void> waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }
  _recoveryWaiters.clear();
}

/// [path] 所在「卷」的键：同一个键上的路径共享同一个挂载，卡住时一起卡住。
///
/// Windows：盘符根（`Z:\`）或 UNC 共享根（`\\server\share\`），大小写不敏感。
/// POSIX：根下前两级（`/Volumes/nas`、`/mnt/share`、`/run/user`）——网络挂载点通常就在
/// 这一层；取得再浅会把整台机器都算成一个卷，一处卡住全盘熔断。
String mediaVolumeKeyOf(String path) {
  if (_looksLikeWindowsPath(path)) {
    // rootPrefix 给 `Z:\` / `z:/` / `\\server\share\`：统一分隔符、去尾分隔符、转小写。
    String root = p.windows.rootPrefix(path).replaceAll('/', r'\');
    while (root.endsWith(r'\') && root.length > 2) {
      root = root.substring(0, root.length - 1);
    }
    return root.toLowerCase();
  }
  final List<String> parts = p.posix.split(p.posix.normalize(path));
  if (parts.isEmpty || parts.first != '/') return parts.isEmpty ? '' : '.';
  return p.posix.joinAll(parts.take(3));
}

bool _looksLikeWindowsPath(String path) =>
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) ||
    path.startsWith(r'\\') ||
    (Platform.isWindows && path.startsWith('//'));

/// [path] 所在的卷当前是否卡着（有超时未返回的 stat）。纯内存查询，不碰文件系统。
bool isMediaVolumeStalled(String path) =>
    _stalledVolumes.containsKey(mediaVolumeKeyOf(path));

/// 等 [path] 所在的卷恢复（卡住的 stat 全部返回）。卷没卡着时立刻完成。
Future<void> whenMediaVolumeRecovered(String path) {
  final String key = mediaVolumeKeyOf(path);
  if (!_stalledVolumes.containsKey(key)) return Future<void>.value();
  final Completer<void> waiter = Completer<void>();
  (_recoveryWaiters[key] ??= <Completer<void>>[]).add(waiter);
  return waiter.future;
}

/// 有界异步探测 [path] 是否存在（见文件头）。永不抛异常、永不同步碰文件系统。
///
/// 只给推测性 / 悬停类路径用：卷卡住时答 [MediaPathPresence.unavailable]，调用方这次
/// 就不做了。导入 / 扫描 / 回填 / 用户主动操作要用 [awaitMediaPathExists]。
Future<MediaPathPresence> probeMediaPath(
  String path, {
  Duration timeout = kMediaPathProbeTimeout,
}) async {
  if (path.isEmpty) return MediaPathPresence.missing;
  final String volume = mediaVolumeKeyOf(path);
  // 卷卡着：不再往卡住的挂载上压新的 stat，直接答「暂不可用」。
  if (_stalledVolumes.containsKey(volume)) return MediaPathPresence.unavailable;
  final Future<bool> query = _inFlight[path] ??= _startQuery(path, volume);
  try {
    final bool exists = await query.timeout(timeout);
    return exists ? MediaPathPresence.present : MediaPathPresence.missing;
  } on TimeoutException {
    _markStalled(volume, query);
    return MediaPathPresence.unavailable;
  } catch (_) {
    // 探测本身出错（权限 / 驱动异常）：说明不了文件不在，按暂不可用。
    return MediaPathPresence.unavailable;
  }
}

/// 必达路径的无时限异步判存在（见文件头「两个入口」）：永不同步碰文件系统，也永不
/// 因为卷慢而给出假答案。
///
/// - 卷卡着：先等它恢复（[whenMediaVolumeRecovered]）再发 stat，不往卡住的挂载上压；
/// - 自己的 stat 过了 [kMediaPathProbeTimeout] 还没回：照样把卷记为卡住（让推测性路径
///   立刻停手），自己接着等这个 stat 的真实答复；
/// - 排队期间卷卡住（stat 被跳过）：等恢复后重来；
/// - stat 本身出错（权限 / 驱动异常）：答 false，与 `File.exists` 的语义一致。
Future<bool> awaitMediaPathExists(String path) async {
  if (path.isEmpty) return false;
  final String volume = mediaVolumeKeyOf(path);
  while (true) {
    if (_stalledVolumes.containsKey(volume)) {
      await whenMediaVolumeRecovered(path);
      continue; // 恢复后可能又被别的 stat 卡住：重新看一眼再发。
    }
    final Future<bool> query = _inFlight[path] ??= _startQuery(path, volume);
    try {
      try {
        return await query.timeout(kMediaPathProbeTimeout);
      } on TimeoutException {
        _markStalled(volume, query);
        return await query;
      }
    } on _VolumeStalledSkip {
      // 这条 stat 排到槽位时卷已卡住、没发出去：清掉它的在飞位，等恢复后重来。
      if (identical(_inFlight[path], query)) _inFlight.remove(path);
      continue;
    } catch (_) {
      return false;
    }
  }
}

Future<bool> _startQuery(String path, String volume) {
  final Future<bool> query = _runWithVolumeSlot(volume, path);
  // 完成（不论成败）即让出在飞位；吞掉这条派生链上的错误，真正的错误由 await 方处理。
  unawaited(
    query.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_inFlight[path], query)) _inFlight.remove(path);
    }),
  );
  return query;
}

Future<bool> _runWithVolumeSlot(String volume, String path) async {
  if ((_volumeActive[volume] ?? 0) >= kMediaProbeConcurrencyPerVolume) {
    final Completer<void> slot = Completer<void>();
    (_volumeQueue[volume] ??= <Completer<void>>[]).add(slot);
    await slot.future;
    // 排队期间卷卡住了：不再往卡住的挂载上压 stat（槽位已转交给本条，原样让出）。
    if (_stalledVolumes.containsKey(volume)) {
      _releaseVolumeSlot(volume);
      throw const _VolumeStalledSkip();
    }
  } else {
    _volumeActive[volume] = (_volumeActive[volume] ?? 0) + 1;
  }
  try {
    return await _existsQuery(path);
  } finally {
    _releaseVolumeSlot(volume);
  }
}

/// 让出一个槽位：有人排队就直接转交（活跃数不变），否则活跃数减一。
void _releaseVolumeSlot(String volume) {
  final List<Completer<void>>? queued = _volumeQueue[volume];
  while (queued != null && queued.isNotEmpty) {
    final Completer<void> next = queued.removeAt(0);
    if (next.isCompleted) continue;
    if (queued.isEmpty) _volumeQueue.remove(volume);
    next.complete();
    return;
  }
  _volumeQueue.remove(volume);
  final int left = (_volumeActive[volume] ?? 1) - 1;
  if (left > 0) {
    _volumeActive[volume] = left;
  } else {
    _volumeActive.remove(volume);
  }
}

void _markStalled(String volume, Future<bool> query) {
  if (!_stalledQueries.add(query)) return;
  _stalledVolumes[volume] = (_stalledVolumes[volume] ?? 0) + 1;
  unawaited(
    query.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (!_stalledQueries.remove(query)) return; // 已被测试重置清掉。
      final int left = (_stalledVolumes[volume] ?? 1) - 1;
      if (left > 0) {
        _stalledVolumes[volume] = left;
        return;
      }
      _stalledVolumes.remove(volume);
      final List<Completer<void>>? waiters = _recoveryWaiters.remove(volume);
      if (waiters == null) return;
      for (final Completer<void> waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }),
  );
}
