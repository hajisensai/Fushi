/// 视频文件技术规格的读取与按需探测（v95）。
///
/// UI 的约束决定了这个模块的形状：库页在 `build` 里同步渲染几十张卡，**不能 await**。
/// 所以对外只有一个同步读 [specsFor]（命中内存缓存就给，没有就返回 null），另有一个
/// [prime] 让调用方把「我这一屏要用到的路径」交进来——GridView 只 build 可见项与缓存
/// 区，于是天然只探可见的那些，不会因为库里有几千个文件就把它们全 ffprobe 一遍。
///
/// 三层：内存 map（渲染读它）→ `video_file_specs` 表（跨启动持久）→ ffprobe（最后手段）。
///
/// 失效判据是「文件大小 + 修改时刻 + 探测器字段集版本」三者全等，任一不同就重探：
/// 用户换了个同名的高清片源、补录了音轨，或者我们自己扩了探测字段，缓存都必须让路。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/models/app_model.dart' show appProvider;

/// 同时在跑的 ffprobe 进程数上限。
///
/// 2 而不是更多：探测只读 header（几十毫秒），瓶颈是进程启动与磁盘寻道；开太多会在
/// 机械盘/网络盘上互相抢寻道，反而更慢，还会跟正在播放的视频抢 IO。
const int kVideoSpecsProbeConcurrency = 2;

/// 等待队列的容量上限。
///
/// 队列是**栈**：最近一次 [VideoSpecsService.prime] 交进来的路径就是用户正在看的
/// 那一屏，必须最先探。溢出时从**栈底**丢——栈底恰好是最早入队、早已滚出视口的那些，
/// 丢掉它们没有任何损失（下次滚回去会重新 prime）。
///
/// 没有这个上限时，快速下滑几秒就能把几百条早已离屏的路径排进队列，而当前视口排在
/// 队尾，角标要等前面几百个 ffprobe 跑完才浮出来。
const int kVideoSpecsQueueCapacity = 256;

/// 取服务实例。生命周期归 `AppModel`（那里懒建、db 关闭时销毁）。
///
/// **必须是普通 [Provider]，不能是 `ChangeNotifierProvider`**：后者会给它返回的
/// notifier 注册 `onDispose(notifier.dispose)`，也就是说 provider 一旦重算，上一次
/// 的返回值就被 dispose。而这里返回的是 AppModel 持有并复用的那一个实例——它会被
/// 就地打死，AppModel 毫不知情、继续把这个死实例发给所有人（`_disposed` 让全部探测
/// 短路，重算时的 `addListener` 还会直接抛断言）。
///
/// 触发条件一点也不罕见：`appProvider` 本身是 `ChangeNotifierProvider<AppModel>`，
/// riverpod 对 ChangeNotifier 恒判 `updateShouldNotify = true`，于是**每一次**
/// `AppModel.notifyListeners()`（写设置、扫描、播放进度…）都会让本 provider 重算。
/// 机制由 `test/media/video/video_specs_provider_lifecycle_test.dart` 钉住。
///
/// 消费方拿到实例后用 `ListenableBuilder` 订阅变化——重建面照样收敛在角标子树，
/// 服务通知频率高（滚一屏几十次），绝不能经 AppModel 的 `notifyListeners` 转发。
final videoSpecsProvider = Provider<VideoSpecsService>(
  (ref) => ref.watch(appProvider).videoSpecsService,
);

/// 规格服务。挂在 [AppModel] 之下，库页与详情页共用一份缓存。
class VideoSpecsService extends ChangeNotifier {
  VideoSpecsService(this._db, {this.probe = probeVideoFacts});

  final FushiDatabase _db;

  /// 探测入口，可注入以便单测不真起 ffprobe。
  final Future<VideoProbeFacts> Function(String path) probe;

  /// 已知规格。**value 可为 null**：null = 已经查过、这个文件探不出规格（没装
  /// ffprobe / 文件损坏 / 是流 URL），用来防止对同一个失败文件反复重试。
  final Map<String, VideoProbeFacts?> _cache = <String, VideoProbeFacts?>{};

  final Queue<String> _queue = Queue<String>();
  final Set<String> _queued = <String>{};

  /// 在途探测：路径 → 那一次探测的 Future。**「已排队」与「正在跑」共用这一张表**，
  /// 于是同一文件同时只会有一个 ffprobe，也只会有一个 Future 被多方 await（见 [_schedule]）。
  final Map<String, Future<VideoProbeFacts?>> _inFlight =
      <String, Future<VideoProbeFacts?>>{};

  /// 已排队但还没轮到的路径 → 它那一次探测的 completer。出队时交给 [_pump]。
  final Map<String, Completer<VideoProbeFacts?>> _pending =
      <String, Completer<VideoProbeFacts?>>{};

  /// 每个路径当前有几个活着的 widget 需要它。见 [retain] / [release]。
  final Map<String, int> _holds = <String, int>{};

  /// 真正在跑 ffprobe 的个数（**不含**还在栈里等的）。
  int _running = 0;
  bool _disposed = false;

  /// 同步读一个文件的规格。没探过或探不出返回 null。
  ///
  /// **不触发探测**——渲染路径必须是纯读。要探请先调 [prime]。
  VideoProbeFacts? specsFor(String? filePath) {
    if (filePath == null || filePath.isEmpty) return null;
    return _cache[filePath];
  }

  /// 是否已经对这个路径有过结论（不论探到与否）。
  bool isResolved(String? filePath) =>
      filePath != null && _cache.containsKey(filePath);

  /// 把一批路径纳入视野：先一条查询批量读库，仍缺的排进后台探测队列。
  ///
  /// 幂等且可高频调用——库页每次滚动都会调它，已知的路径直接跳过。
  Future<void> prime(Iterable<String> filePaths) async {
    if (_disposed) return;
    final List<String> unknown = <String>[
      for (final String path in filePaths.toSet())
        if (path.isNotEmpty &&
            !_cache.containsKey(path) &&
            !_inFlight.containsKey(path))
          path,
    ];
    if (unknown.isEmpty) return;

    // 先批量读库：绝大多数情况下这一步就够了，一条 IN 查询换掉几十次 ffprobe。
    //
    // 整段裹 try：本方法是从 widget 的 initState 里 fire-and-forget 调用的，抛出去
    // 就是无人接管的异步错误。db 在卡片还挂着时被关掉是真实场景（数据根迁移、切
    // Profile、恢复备份都会 close/reopen FushiDatabase），那时应当安静地退化成
    // 「这批没读到」，而不是把异常抛进 zone。
    Map<String, VideoFileSpecRow> rows = const <String, VideoFileSpecRow>{};
    try {
      rows = await _db.videoFileSpecsByPath(unknown);
    } catch (e) {
      debugPrint('[VideoSpecsService] prime read failed: $e');
    }
    if (_disposed) return;

    bool changed = false;
    for (final String path in unknown) {
      final VideoFileSpecRow? row = rows[path];
      if (row != null && await _rowIsFresh(row)) {
        _cache[path] = videoProbeFactsFromRow(row);
        changed = true;
        continue;
      }
      // 库里没有、或已过期 → 压进探测栈。
      unawaited(_schedule(path));
    }
    if (changed) notifyListeners();
  }

  /// 立刻探一个文件并等结果（详情页用：只有一个文件，值得等）。
  ///
  /// 与队列共用缓存、失效判据**和在途集合**，不会重复探。
  Future<VideoProbeFacts?> resolve(String filePath) async {
    if (filePath.isEmpty) return null;
    if (_cache.containsKey(filePath)) return _cache[filePath];

    // 同一个文件很容易两条路径同时进来：集卡渲染 prime() 把它排进栈，用户紧接着
    // 打开该集的「媒体信息」弹窗触发 resolve()。共用在途表就只探一次——否则会起第二个
    // ffprobe，正好废掉 kVideoSpecsProbeConcurrency 想守的东西（别跟正在播放的视频抢 IO）。
    final Future<VideoProbeFacts?>? inFlight = _inFlight[filePath];
    if (inFlight != null) {
      _bumpToTop(filePath);
      return inFlight;
    }

    VideoFileSpecRow? row;
    try {
      row = await _db.videoFileSpec(filePath);
    } catch (e) {
      // 与 prime() 同理：db 可能已在别处被关掉，安静退化成「没缓存」去现探。
      debugPrint('[VideoSpecsService] resolve read failed for "$filePath": $e');
    }
    if (_disposed) return null;
    if (row != null && await _rowIsFresh(row)) {
      final VideoProbeFacts facts = videoProbeFactsFromRow(row);
      _cache[filePath] = facts;
      notifyListeners();
      return facts;
    }

    // **不自己起探测**：压栈顶再等。栈顶意味着下一个空出来的槽就是它的，用户打开的
    // 那个文件依然最先探；而并发闸门只有 [_pump] 一个执行入口，`kVideoSpecsProbeConcurrency`
    // 才是真上限。早先这里直接起探测，闸门只管住队列那一半，详情页一开就能有 3 个
    // ffprobe 同时跑。
    return _schedule(filePath);
  }

  /// 排一次探测，**同一路径共用同一个 Future**。
  ///
  /// 这是**唯一**的探测入口：队列消费与详情页直探都经过它，所以「一个文件同时被探
  /// 两次」和「并发数越过上限」在结构上不可能发生，而不是靠两处各自记得检查对方的集合。
  Future<VideoProbeFacts?> _schedule(String path) {
    final Future<VideoProbeFacts?>? existing = _inFlight[path];
    if (existing != null) {
      _bumpToTop(path);
      return existing;
    }
    final Completer<VideoProbeFacts?> completer = Completer<VideoProbeFacts?>();
    _pending[path] = completer;
    _inFlight[path] = completer.future;
    _queue.addLast(path);
    _queued.add(path);
    while (_queue.length > kVideoSpecsQueueCapacity) {
      // 栈底 = 最早入队 = 早就滚出视口。丢掉不写缓存（没有得出任何结论），
      // 于是 isResolved 仍为 false，下次滚回去会重新排。
      final String dropped = _queue.removeFirst();
      _queued.remove(dropped);
      _inFlight.remove(dropped);
      _pending.remove(dropped)?.complete(null);
    }
    _pump();
    return completer.future;
  }

  /// 把一个还没轮到的路径提到栈顶（用户又滚回来了，或正好打开了它的详情页）。
  /// 声明「有一个活着的 widget 正需要这个路径」。与 [release] 成对。
  ///
  /// 队列纪律（FIFO 还是 LIFO）本身拿不到「谁在视口里」这个信息，而 widget 的生命
  /// 周期拿得到，且对两种宿主形状都成立：
  ///  * 惰性库页（`SliverGrid.builder`）——滚出视口即 dispose，队列自然收敛到当前屏；
  ///  * 非惰性合集页（`FushiReorderableGrid` 全量构建）——整页关闭才 dispose，于是
  ///    整季按构建序（= 从上到下）排队，这也正是那一页想要的顺序。
  ///
  /// 没有它时，快速下滑几秒就能把几百条早已离屏的路径留在队列里，当前视口排在最后。
  void retain(String path) {
    if (path.isEmpty) return;
    _holds[path] = (_holds[path] ?? 0) + 1;
  }

  /// 撤回一次 [retain]。最后一个持有者走人、且该路径**还没轮到探测**时把它撤下队列。
  ///
  /// 已经在跑的不撤——ffprobe 进程已经起来了，半路丢弃只会浪费掉已付出的开销，
  /// 而结果本身跨启动有效（落库），下次滚回来直接命中。
  void release(String path) {
    if (path.isEmpty) return;
    final int? held = _holds[path];
    if (held == null) return;
    if (held > 1) {
      _holds[path] = held - 1;
      return;
    }
    _holds.remove(path);
    if (!_queued.contains(path)) return; // 已在跑 / 已完成
    _queue.remove(path);
    _queued.remove(path);
    _inFlight.remove(path);
    // 不写 _cache：没有得出任何结论，isResolved 保持 false，下次滚回来会重新排。
    _pending.remove(path)?.complete(null);
  }

  void _bumpToTop(String path) {
    if (!_queued.contains(path)) return; // 已经在跑，无所谓次序
    _queue.remove(path);
    _queue.addLast(path);
  }

  /// 把栈跑到并发上限。每完成一个就再拉一个，不用定时器轮询。
  void _pump() {
    while (!_disposed &&
        _running < kVideoSpecsProbeConcurrency &&
        _queue.isNotEmpty) {
      final String path = _queue.removeLast();
      _queued.remove(path);
      final Completer<VideoProbeFacts?>? completer = _pending.remove(path);
      if (completer == null) continue; // 已被溢出丢弃

      // **出队时才复查缓存**：入队到出队之间隔着前面所有排队项，这中间详情页的
      // resolve() 或别处完全可能已经把它探完写进缓存。不复查就是对同一个文件起
      // 第二个 ffprobe。
      if (_cache.containsKey(path)) {
        _inFlight.remove(path);
        completer.complete(_cache[path]);
        continue;
      }

      _running++;
      unawaited(() async {
        VideoProbeFacts? result;
        try {
          result = await _probeAndStore(path);
        } catch (e) {
          // _probeAndStore 自己已经分层兜住了探测与落库的异常；这里是最后一道，
          // 保证无论如何都不会有未捕获异步错误，也不会把槽位漏掉。
          debugPrint('[VideoSpecsService] probe task failed for "$path": $e');
        } finally {
          _running--;
          _inFlight.remove(path);
          if (!completer.isCompleted) completer.complete(result);
          _pump();
        }
      }());
    }
  }

  /// 等队列与在途探测全部落地。
  ///
  /// 只给测试用。测试若靠「让出 N 轮事件循环」来等异步队列，N 就成了一个随实现层数
  /// 漂移的魔数——探测链上多包一层 `whenComplete` 就可能不够，表现为随机的
  /// 「should have been probed」失败，且会把未完成的任务漏给下一个用例。
  @visibleForTesting
  Future<void> drain() async {
    while (!_disposed && (_inFlight.isNotEmpty || _queue.isNotEmpty)) {
      if (_inFlight.isEmpty) {
        // 队列里还有，但还没被 _pump 拉起来——让出一轮再看。
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      await Future.wait<VideoProbeFacts?>(
        _inFlight.values.toList(growable: false),
      );
    }
  }

  /// 丢弃一个文件的缓存（文件被删/被替换时）。
  Future<void> invalidate(String filePath) async {
    _cache.remove(filePath);
    try {
      await _db.deleteVideoFileSpec(filePath);
    } catch (e) {
      // 与 prime()/resolve() 同理：db 可能已在别处被关掉。内存缓存已经清了，
      // 库里那行过期就过期，失效判据（大小+修改时刻+字段集版本）下次会兜住。
      debugPrint('[VideoSpecsService] invalidate failed for "$filePath": $e');
    }
    if (!_disposed) notifyListeners();
  }

  /// 真探一次并落库。
  ///
  /// **探测失败与落库失败分开处理**：探测失败才在 [_cache] 里记 null（已问过，别再问）；
  /// 落库失败只是丢了跨启动的缓存，本次会话探到的事实照样有效——把它一起判死会让角标
  /// 在 ffprobe 明明成功的情况下消失，而且 `isResolved` 已为 true，再也不会重试。
  Future<VideoProbeFacts?> _probeAndStore(String path) async {
    final FileStat stat;
    final VideoProbeFacts facts;
    try {
      stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.notFound) {
        _cache[path] = null;
        return null;
      }
      facts = await probe(path);
    } catch (e) {
      debugPrint('[VideoSpecsService] probe failed for "$path": $e');
      _cache[path] = null;
      return null;
    }
    if (_disposed) return null;
    if (facts.isEmpty) {
      // 探不出就不落库——写一个空壳会让它永远「命中缓存」，再也不会重试。
      _cache[path] = null;
      notifyListeners();
      return null;
    }
    _cache[path] = facts;
    try {
      await _db.upsertVideoFileSpec(videoFileSpecCompanion(
        filePath: path,
        facts: facts,
        fileSizeBytes: stat.size,
        fileModifiedAt: stat.modified.millisecondsSinceEpoch,
      ));
    } catch (e) {
      // 库写不进去（磁盘满 / 迁移中把 db 关了 / 约束冲突）不影响本次结果，
      // 只是下次启动要重探一遍。
      debugPrint('[VideoSpecsService] persist failed for "$path": $e');
    }
    if (!_disposed) notifyListeners();
    return facts;
  }

  /// 缓存行是否仍代表磁盘上那个文件。
  Future<bool> _rowIsFresh(VideoFileSpecRow row) async {
    if (row.probeVersion != kVideoProbeFieldSetVersion) return false;
    final FileStat stat = await FileStat.stat(row.filePath);
    if (stat.type == FileSystemEntityType.notFound) return false;
    return stat.size == row.fileSizeBytes &&
        stat.modified.millisecondsSinceEpoch == row.fileModifiedAt;
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    _queued.clear();
    // 还在等的 resolve() 必须收到结果，否则详情页那个 await 永远挂着。
    for (final Completer<VideoProbeFacts?> c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
    _inFlight.clear();
    _holds.clear();
    super.dispose();
  }
}

/// DB 行 → 探测事实。
///
/// 刻意复用 [VideoProbeFacts] 而不是另立一个「已落库的规格」类：两者是同一份事实的
/// 两种存放形态，各写一个类就得写一套互转，还得保证两边字段永远同步。
VideoProbeFacts videoProbeFactsFromRow(VideoFileSpecRow row) => VideoProbeFacts(
      durationMs: row.durationMs,
      fileSizeBytes: row.fileSizeBytes,
      containerBitrate: row.containerBitrate,
      video: _videoStreamFromRow(row),
      audioTracks: decodeTrackListJson<AudioTrackFacts>(
        row.audioTracksJson,
        AudioTrackFacts.fromJson,
      ),
      subtitleTracks: decodeTrackListJson<SubtitleTrackFacts>(
        row.subtitleTracksJson,
        SubtitleTrackFacts.fromJson,
      ),
    );

/// 视频流那部分全为空时返回 null——纯音频文件与「探到了但没视频流」应当同形。
VideoStreamFacts? _videoStreamFromRow(VideoFileSpecRow row) {
  if (row.width == null &&
      row.height == null &&
      row.videoCodec == null &&
      row.pixelFormat == null) {
    return null;
  }
  return VideoStreamFacts(
    codec: row.videoCodec,
    width: row.width,
    height: row.height,
    pixelFormat: row.pixelFormat,
    bitDepth: row.bitDepth,
    frameRateMilli: row.frameRateMilli,
    bitrate: row.videoBitrate,
    colorPrimaries: row.colorPrimaries,
    colorTransfer: row.colorTransfer,
    colorSpace: row.colorSpace,
  );
}

/// 探测事实 → 待写入的 DB 行。
VideoFileSpecsCompanion videoFileSpecCompanion({
  required String filePath,
  required VideoProbeFacts facts,
  required int fileSizeBytes,
  required int fileModifiedAt,
  DateTime? now,
}) {
  final VideoStreamFacts? video = facts.video;
  return VideoFileSpecsCompanion.insert(
    filePath: filePath,
    fileSizeBytes: fileSizeBytes,
    fileModifiedAt: fileModifiedAt,
    probedAt: (now ?? DateTime.now()).millisecondsSinceEpoch,
    probeVersion: kVideoProbeFieldSetVersion,
    durationMs: Value<int?>(facts.durationMs),
    containerBitrate: Value<int?>(facts.containerBitrate),
    videoCodec: Value<String?>(video?.codec),
    width: Value<int?>(video?.width),
    height: Value<int?>(video?.height),
    pixelFormat: Value<String?>(video?.pixelFormat),
    bitDepth: Value<int?>(video?.bitDepth),
    frameRateMilli: Value<int?>(video?.frameRateMilli),
    videoBitrate: Value<int?>(video?.bitrate),
    colorPrimaries: Value<String?>(video?.colorPrimaries),
    colorTransfer: Value<String?>(video?.colorTransfer),
    colorSpace: Value<String?>(video?.colorSpace),
    audioTracksJson: Value<String>(encodeTrackListJson(<Map<String, Object?>>[
      for (final AudioTrackFacts t in facts.audioTracks) t.toJson(),
    ])),
    subtitleTracksJson:
        Value<String>(encodeTrackListJson(<Map<String, Object?>>[
      for (final SubtitleTrackFacts t in facts.subtitleTracks) t.toJson(),
    ])),
  );
}
