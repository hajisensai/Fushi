import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_asr_core/asr_core.dart'
    show AsrAudioProfile, AsrLanguage, asrModelPackFor, ModelDownloadEvent;

/// 本机模型下载的**全应用单飞登记表**（[sharedModelDownloads]）：同一份模型目录
/// 同一时刻只允许一条下载在写。
///
/// 为什么需要（kZZmXQBv7E）：语音识别模型 / MOSS 的下载入口有好几个——视频「生成
/// 日语字幕」弹层、有声书转录弹层、设置页、`fushi_cli`、导入后自动转录——以前各自
/// 直接调 `downloadModel` / `ensureMossProvisioned`，下载订阅挂在页面上：
/// - 关掉弹层后 `await for` 还在后台写，但重新打开的弹层看不到它，按钮又亮了；
/// - 再点一次就起第二条下载，两条流同时往同一个 `.part` 里 append，`.part` 被写得
///   比真实文件还长，之后每次 Range 续传都拿到 HTTP 416，永远下不完。
///
/// 这里把「下载」的所有权从页面收归进程：按 [key]（一份模型目录一个键）单飞——
/// 已在下的再 [join] 只是挂上去看进度（先补发最近一条事件），不另起写者；监听方
/// 取消订阅（关弹层）**不**停下载，只有 [cancel] 才停。页面重开时用 [attach] 接回
/// 进行中的那条。
class SharedModelDownloads extends ChangeNotifier {
  final Map<String, _Flight> _flights = <String, _Flight>{};

  /// [key] 是否正在下载。
  bool isActive(String key) => _flights.containsKey(key);

  /// [key] 进行中下载的最近一条事件；没在下载 / 还没收到事件为 null。
  ModelDownloadEvent? latestOf(String key) => _flights[key]?.latest;

  /// 发起或挂上 [key] 的下载：没在下时调 [start] 起一条（由本登记表持有订阅），
  /// 已在下时直接挂上去。返回的流先补发最近一条事件，之后逐条转发，下载结束 /
  /// 失败时随之结束 / 报错。
  Stream<ModelDownloadEvent> join(
    String key,
    Stream<ModelDownloadEvent> Function() start,
  ) {
    final _Flight flight = _flights[key] ?? _start(key, start);
    return flight.watch();
  }

  /// 接回 [key] 进行中的下载；没在下时为 null（页面初始化时用，不发起下载）。
  Stream<ModelDownloadEvent>? attach(String key) => _flights[key]?.watch();

  /// 停掉 [key] 的下载（已落盘的 `.part` 留着，下次由下载器 Range 续上）。挂着的
  /// 监听方收到 done。
  Future<void> cancel(String key) async {
    final _Flight? flight = _flights.remove(key);
    if (flight == null) return;
    notifyListeners();
    await flight.cancel();
  }

  _Flight _start(String key, Stream<ModelDownloadEvent> Function() start) {
    late final _Flight flight;
    flight = _Flight(
      onEvent: notifyListeners,
      onEnd: () {
        if (identical(_flights[key], flight)) {
          _flights.remove(key);
          notifyListeners();
        }
      },
    );
    _flights[key] = flight;
    flight.run(start());
    notifyListeners();
    return flight;
  }
}

class _Flight {
  _Flight({required this.onEvent, required this.onEnd});

  final VoidCallback onEvent;
  final VoidCallback onEnd;

  /// 每个监听方一个单订阅控制器，手动扇出：监听方取消只摘掉自己，不影响下载。
  final List<StreamController<ModelDownloadEvent>> _watchers =
      <StreamController<ModelDownloadEvent>>[];
  StreamSubscription<ModelDownloadEvent>? _sub;
  ModelDownloadEvent? latest;
  bool _ended = false;
  Object? _error;
  StackTrace? _stack;

  void run(Stream<ModelDownloadEvent> source) {
    _sub = source.listen(
      (ModelDownloadEvent event) {
        latest = event;
        for (final StreamController<ModelDownloadEvent> c
            in List<StreamController<ModelDownloadEvent>>.of(_watchers)) {
          c.add(event);
        }
        onEvent();
      },
      onError: (Object error, StackTrace stack) {
        _error = error;
        _stack = stack;
        _end();
      },
      onDone: _end,
      cancelOnError: true,
    );
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    final List<StreamController<ModelDownloadEvent>> watchers =
        List<StreamController<ModelDownloadEvent>>.of(_watchers);
    _watchers.clear();
    for (final StreamController<ModelDownloadEvent> c in watchers) {
      _closeWatcher(c);
    }
    onEnd();
  }

  void _closeWatcher(StreamController<ModelDownloadEvent> c) {
    final Object? error = _error;
    if (error != null) c.addError(error, _stack);
    unawaited(c.close());
  }

  Future<void> cancel() async {
    await _sub?.cancel();
    _end();
  }

  /// 一个监听方视角的流：先补最近一条，再转发；在它订阅前就已结束（含失败）的，
  /// 补发结局。监听方取消只摘掉自己。
  Stream<ModelDownloadEvent> watch() {
    late final StreamController<ModelDownloadEvent> c;
    c = StreamController<ModelDownloadEvent>(
      onListen: () {
        final ModelDownloadEvent? last = latest;
        if (last != null) c.add(last);
        if (_ended) {
          _closeWatcher(c);
        } else {
          _watchers.add(c);
        }
      },
      onCancel: () {
        _watchers.remove(c);
      },
    );
    return c.stream;
  }
}

/// 全应用唯一的模型下载单飞登记表。
final SharedModelDownloads sharedModelDownloads = SharedModelDownloads();

/// 语音识别模型包的单飞键：一个包一份目录，按包 id 单飞（同包不同变体共享
/// `vocab` 等文件，也不能并发写）。
String asrPackDownloadKey(String packId) => 'asr:$packId';

/// [language] 在 [profile] 素材下当前选中的那个包的单飞键（与转录服务
/// `downloadModel` 落盘的目录一致：服务内部同样经 `asrModelPackFor` 取包）。
String asrDownloadKeyFor(AsrLanguage language, AsrAudioProfile profile) =>
    asrPackDownloadKey(asrModelPackFor(language, profile: profile).id);

/// MOSS（audio.cpp 运行库 + 权重）的单飞键。各后端共用同一份权重，所以不分后端。
const String kMossDownloadKey = 'moss';
