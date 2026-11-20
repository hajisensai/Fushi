// 词典资源目录的「触读物化」探测（BUG-2504）。
//
// 不变式：**主 isolate 上的同步 FFI 装载只能碰已物化（materialized）的字节。**
//
// 背景：macOS 的 `getApplicationDocumentsDirectory()` 就是 `~/Documents`，开了
// iCloud「桌面与文稿」+「优化储存空间」后，`~/Documents/Fushi/data/dictionaryResources/
// <name>/*` 会被驱逐成 dataless（Finder 里的「仅云端」）文件；Windows 的 OneDrive
// 「按需文件」对 `%USERPROFILE%\Documents` 同理。冷启动装词典的链路是
// `AppModel._rebuildDictPathsCacheAsync` → `FushiDicts.scheduleTyped` →
// `FushiDicts.loadPendingAsync`（逐本 `addTermDict` 是**主 isolate 上的同步 FFI**）→
// C++ `add_dict` 用 `std::ifstream` 整读 `index.json` / `styles.css` / `dict.zstd`，
// `mmap` 索引（`key.index`，旧式 `hash.table` / `bloom.filter`）、`blobs.bin` /
// `blobs3.bin` / `media.bin` / `media.idx` 并立即
// 触页。读到 dataless 文件会在内核里同步等云端把整个文件拉回来，没有任何超时；而
// AppModel 的 12s 看门狗与 main.dart 的 20s 逃生 UI 都是 Timer，在同步 FFI 阻塞期间
// 根本不会触发——用户看到的就是冷启动永远转圈。
//
// 做法：装载前在**后台 isolate**对每本词典目录逐文件 `open` + 读 1 字节。对 File
// Provider / OneDrive 而言读任意一个字节就会把整个文件拉回本地（物化），而后台
// isolate 阻塞不影响主 isolate 与看门狗。整批带一个总预算：预算内确认「全部文件
// 可读」的词典才进本次装载；超时 / 读失败的词典本次跳过，探测 isolate 继续跑完把
// 文件拉回来，下次启动就能装。
//
// 所有平台统一走这条：代价是每本 ~8 次 open/read 1 字节（毫秒级），换来的是一个
// 永久的鲁棒层——它不是某个云盘的兼容特判，而是「装载前先证明字节在本地」这条
// 不变式的执行者。
//
// 本文件只依赖 `dart:io` / `dart:isolate`：worker 跑在 `Isolate.spawn` 出来的后台
// isolate 里，那里没有 Flutter binding，`ErrorLogService` / `debugPrint` 都不可用；
// 日志由调用方（`AppModel`）在主 isolate 记。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// 生产默认的整批物化预算。
///
/// 8 秒是「本地磁盘上几十本词典毫秒级跑完」与「AppModel 的 12s 启动 IO 看门狗
/// （`_initIoTimeout`）之内还给真正的装载留出余量」之间取的值：预算耗尽只是让
/// 本次启动少装几本词典，不是错误。
const Duration kDictResourceMaterializeBudget = Duration(seconds: 8);

/// [materializeDictResources] 的结果。三个集合互不重叠，并集恰好等于输入目录集。
class DictResourceMaterializeResult {
  const DictResourceMaterializeResult({
    required this.ready,
    required this.pending,
    required this.failed,
  });

  /// 预算内确认目录下全部常规文件都可读（已物化）的词典目录，保持输入顺序。
  final List<String> ready;

  /// 预算耗尽时仍未回报的词典目录，保持输入顺序。它们的探测仍在后台 isolate 里
  /// 继续（会把文件真正拉回本地），只是本次装载不等它们。
  final List<String> pending;

  /// 探测出错的词典目录 → 错误串（目录不存在、列目录失败、某个文件打不开/读不出）。
  final Map<String, String> failed;

  /// 三个集合都空：输入为空时的快捷返回。
  static const DictResourceMaterializeResult empty =
      DictResourceMaterializeResult(
        ready: <String>[],
        pending: <String>[],
        failed: <String, String>{},
      );
}

/// 在后台 isolate 里对 [dictDirs] 逐目录做触读物化探测，最多等 [budget]。
///
/// - 目录会按给出的顺序探测，每做完一个目录就回报一次；[budget] 到期后停止等待，
///   未回报的目录归入 [DictResourceMaterializeResult.pending]。
/// - **不 kill worker isolate**：它会继续把剩余目录的文件读一遍（也就是把 dataless
///   文件拉回本地），之后自行退出。预算后到达的回报经 [onLateReport] 通知调用方
///   （只用于诊断日志，不改变已返回的结果）。
/// - 不存在的目录归入 `failed`（错误串以 `directory missing` 开头），调用方无需先过滤。
/// - [debugPerDirectoryDelay] 仅供测试：让 worker 在每个目录前 `sleep` 这么久，用来
///   确定性地制造「预算耗尽」而不靠机器快慢赌时序。
Future<DictResourceMaterializeResult> materializeDictResources(
  List<String> dictDirs, {
  Duration budget = kDictResourceMaterializeBudget,
  void Function(String dir, String? error)? onLateReport,
  Duration debugPerDirectoryDelay = Duration.zero,
}) async {
  if (dictDirs.isEmpty) return DictResourceMaterializeResult.empty;

  final ReceivePort port = ReceivePort('dict-resource-materializer');
  final Map<String, String?> reports = <String, String?>{};
  final Completer<void> finished = Completer<void>();
  // 预算到期后置 true：之后到的回报走 [onLateReport]，不再写进 [reports]。
  bool budgetExpired = false;

  void settle() {
    if (!finished.isCompleted) finished.complete();
  }

  port.listen((Object? message) {
    if (message is _DirReport) {
      if (budgetExpired) {
        onLateReport?.call(message.dir, message.error);
      } else {
        reports[message.dir] = message.error;
      }
      return;
    }
    if (message == _doneToken) {
      port.close();
      settle();
      return;
    }
    // `onError` 端口送来的未捕获 isolate 错误（`[error, stackTrace]`）：worker 里
    // 逐目录都包了 try/catch，能走到这里只可能是列表之外的崩溃。把还没回报的目录
    // 全部判为 failed，别让它们被当成「超时」而被误认为「下次会好」。
    final String error = message is List && message.isNotEmpty
        ? 'materializer isolate crashed: ${message.first}'
        : 'materializer isolate crashed: $message';
    for (final String dir in dictDirs) {
      if (budgetExpired) {
        onLateReport?.call(dir, error);
      } else {
        reports.putIfAbsent(dir, () => error);
      }
    }
    port.close();
    settle();
  });

  try {
    await Isolate.spawn<_MaterializeRequest>(
      _materializeWorker,
      _MaterializeRequest(
        List<String>.unmodifiable(dictDirs),
        port.sendPort,
        debugPerDirectoryDelay,
      ),
      onError: port.sendPort,
      debugName: 'dict-resource-materializer',
    );
  } catch (e) {
    // 连 isolate 都起不来（极端低内存等）：一个都不判 ready——不变式是「证明字节在
    // 本地才装」，证不了就不装，而不是退回到会卡死的老路。
    port.close();
    return DictResourceMaterializeResult(
      ready: const <String>[],
      pending: const <String>[],
      failed: <String, String>{
        for (final String dir in dictDirs) dir: 'materializer spawn failed: $e',
      },
    );
  }

  await finished.future.timeout(budget, onTimeout: () {});
  budgetExpired = true;

  final List<String> ready = <String>[];
  final List<String> pending = <String>[];
  final Map<String, String> failed = <String, String>{};
  final Set<String> seen = <String>{};
  for (final String dir in dictDirs) {
    // 同一目录在输入里出现两次时只归一次类，保证三个集合的并集 == 输入去重集。
    if (!seen.add(dir)) continue;
    if (!reports.containsKey(dir)) {
      pending.add(dir);
      continue;
    }
    final String? error = reports[dir];
    if (error == null) {
      ready.add(dir);
    } else {
      failed[dir] = error;
    }
  }
  return DictResourceMaterializeResult(
    ready: ready,
    pending: pending,
    failed: failed,
  );
}

const String _doneToken = 'dict-resource-materializer-done';

/// 可跨 isolate 传递的探测请求。
class _MaterializeRequest {
  const _MaterializeRequest(this.dirs, this.sendPort, this.perDirectoryDelay);
  final List<String> dirs;
  final SendPort sendPort;
  final Duration perDirectoryDelay;
}

/// 一个目录的探测回报：[error] 为 null 表示全部文件可读。
class _DirReport {
  const _DirReport(this.dir, this.error);
  final String dir;
  final String? error;
}

/// 后台 isolate 入口：逐目录、逐文件触读 1 字节。
///
/// 只看目录下的**常规文件**（`listSync(followLinks: false)` 里的 [File]），不硬编码
/// 文件名清单——引擎文件集合以磁盘为准；典型的是 `index.json` / `styles.css` /
/// `dict.zstd` / `key.index`（旧式 `hash.table` / `bloom.filter`）/ `blobs.bin` /
/// `blobs3.bin` / `media.bin` / `media.idx`。
/// 子目录与符号链接跳过：引擎不会 mmap 它们。
void _materializeWorker(_MaterializeRequest request) {
  final SendPort port = request.sendPort;
  for (final String dir in request.dirs) {
    if (request.perDirectoryDelay > Duration.zero) {
      sleep(request.perDirectoryDelay);
    }
    port.send(_DirReport(dir, _materializeDirectory(dir)));
  }
  port.send(_doneToken);
}

/// 探测一个目录，返回 null 表示全部文件可读；否则返回错误串。
String? _materializeDirectory(String dir) {
  final Directory directory = Directory(dir);
  try {
    if (!directory.existsSync()) return 'directory missing: $dir';
    final List<FileSystemEntity> entries = directory.listSync(
      followLinks: false,
    );
    for (final FileSystemEntity entity in entries) {
      if (entity is! File) continue;
      final RandomAccessFile raf = entity.openSync();
      try {
        // 读 1 字节就足以让 File Provider / OneDrive 把整个文件拉回本地；
        // 空文件 readSync 返回空列表，同样算可读。
        raf.readSync(1);
      } finally {
        raf.closeSync();
      }
    }
    return null;
  } catch (e) {
    return '$e';
  }
}

/// [materializeDictResources] 的函数形状，供 [DictResourceAvailability] 注入（测试用
/// 假探测器确定性地制造「预算后回报」）。
typedef DictResourceProbe =
    Future<DictResourceMaterializeResult> Function(
      List<String> dictDirs, {
      void Function(String dir, String? error)? onLateReport,
    });

Future<DictResourceMaterializeResult> _defaultDictResourceProbe(
  List<String> dictDirs, {
  void Function(String dir, String? error)? onLateReport,
}) => materializeDictResources(dictDirs, onLateReport: onLateReport);

/// [DictResourceAvailability.resolve] 的结果。
class DictResourceResolution {
  const DictResourceResolution({
    required this.ready,
    required this.pending,
    required this.failed,
    required this.probedNow,
  });

  /// 输入里已证明物化（本轮或之前任何一轮）的目录，保持输入顺序。
  final List<String> ready;

  /// 输入里仍有探测 worker 在跑、尚未回报的目录（本轮新起的或之前起的）。
  final List<String> pending;

  /// 本轮探测出错的目录 → 错误串。
  final Map<String, String> failed;

  /// 本轮真正交给探测器的目录（已物化 / 在探的都不再探）。
  final List<String> probedNow;
}

/// 进程内「哪些词典目录的字节已在本地」的唯一状态持有者（BUG-4510）。
///
/// 旧实现把这份状态拆在 `AppModel` 的两个集合里，每次异步重装都对**全部**目录重起
/// 一个探测 worker，并用本轮结果**覆盖**可读集。于是：预算后 worker 每回报一本 →
/// 2s 后重装 → 重装又对全部目录（包括上一轮 worker 还没读到的）起新 worker、预算内
/// 没读完的再次 pending → 新 worker 的回报再触发重装……worker 无界叠加、彼此抢 IO，
/// 每轮还整套重装引擎（主 isolate 同步 FFI），Windows 上窗口消息泵被持续饿死
/// （Application Hang 1002）；可读集被覆盖又让已证明可读的词典反复掉出引擎。
///
/// 这里的不变式：
/// - 已证明物化的目录**单调**累积，不被后续轮次覆盖；
/// - 正在被某个 worker 探的目录不重复探——每个目录同一时刻至多一个在途探测；
/// - 在途集合清空（所有预算后回报到齐）且期间有新目录变可读时，[onLateReady] 只
///   触发一次，由调用方重装一次引擎。
class DictResourceAvailability {
  DictResourceAvailability({
    DictResourceProbe probe = _defaultDictResourceProbe,
    this.onLateReport,
    this.onLateReady,
  }) : _probe = probe;

  final DictResourceProbe _probe;

  /// 每条预算后回报（成功或失败），供调用方记诊断日志。
  final void Function(String dir, String? error)? onLateReport;

  /// 在途探测全部回报完、且其间至少一本变成可读时调用一次：调用方据此重装引擎。
  final void Function()? onLateReady;

  final Set<String> _ready = <String>{};
  final Set<String> _inFlight = <String>{};
  final Set<String> _probed = <String>{};
  bool _lateReadySinceDrain = false;

  /// 已证明字节在本地。
  bool isReady(String dir) => _ready.contains(dir);

  /// 同步装载路径的判据：没探过的目录（本进程刚导入 / 互联落盘的，本就在本地）放行，
  /// 探过的只放行已证明物化的。
  bool isLoadable(String dir) => !_probed.contains(dir) || _ready.contains(dir);

  /// 仍有探测 worker 在跑的目录数。
  int get inFlightCount => _inFlight.length;

  /// 对 [existingDirs] 中「既没证明可读、也没在探」的目录起一次探测并等预算，返回
  /// [existingDirs] 当前的可读 / 在途划分。
  Future<DictResourceResolution> resolve(List<String> existingDirs) async {
    final List<String> toProbe = <String>[
      for (final String dir in existingDirs.toSet())
        if (!_ready.contains(dir) && !_inFlight.contains(dir)) dir,
    ];
    Map<String, String> failed = const <String, String>{};
    if (toProbe.isNotEmpty) {
      _probed.addAll(toProbe);
      _inFlight.addAll(toProbe);
      final DictResourceMaterializeResult result = await _probe(
        toProbe,
        onLateReport: _onLate,
      );
      _ready.addAll(result.ready);
      _inFlight
        ..removeAll(result.ready)
        ..removeAll(result.failed.keys);
      failed = result.failed;
    }
    return DictResourceResolution(
      ready: <String>[
        for (final String dir in existingDirs)
          if (_ready.contains(dir)) dir,
      ],
      pending: <String>[
        for (final String dir in existingDirs)
          if (_inFlight.contains(dir)) dir,
      ],
      failed: failed,
      probedNow: toProbe,
    );
  }

  void _onLate(String dir, String? error) {
    _inFlight.remove(dir);
    if (error == null && _ready.add(dir)) _lateReadySinceDrain = true;
    onLateReport?.call(dir, error);
    if (_inFlight.isEmpty && _lateReadySinceDrain) {
      _lateReadySinceDrain = false;
      onLateReady?.call();
    }
  }
}
