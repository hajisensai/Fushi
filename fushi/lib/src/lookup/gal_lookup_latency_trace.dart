// 游戏内嵌查词的分段耗时记录：从 hook 发布一次点击命中，到查词卡贴到游戏画面上。
//
// 一次 submit 一条记录，结束时只写**一行**日志（glog 每行都是同步落盘，逐段各写一行
// 本身就会把被测的那条链拖慢）。所有时刻统一用 QPC 微秒：hook 与 runner 在命中里带来
// 自己的 QPC 读数，Dart 侧用 `Timeline.now`——它在 Windows 上同样由
// QueryPerformanceCounter 换算成微秒，所以三个进程 / 线程的读数可以直接相减。
//
// 段的含义（每段都是相邻两个时刻之差）：
//   hook→poll   hook 发布 hit → runner 轮询泵读到并投给 Dart
//   poll→dart   runner 投递 → Dart handleHit 收到（平台通道 + UI isolate 排队）
//   其后各段     见 [GalLookupLatencyStage]
//
// 只是诊断：任何一步量不到都只让那一段留空，绝不影响查词本身。

import 'dart:developer' show Timeline;

import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

/// 查词链上被记录的时刻，按发生顺序排列。
enum GalLookupLatencyStage {
  /// 排到查词队列开始执行（前面若有在途查词会在这里等）。
  run('run'),

  /// 换词前的两次 hide 往返完成。
  hide('hide'),

  /// 词典搜索返回。
  search('search'),

  /// 原生 showAt 返回（离屏窗口就位）。
  show('show'),

  /// renderStack 脚本交给 WebView2 执行完毕（Dart 侧 await 返回）。
  renderSent('render'),

  /// 宿主页报回卡片尺寸（首个 overlaySize）。
  measured('measure'),

  /// 宿主页双 rAF 后报 captureReady：新尺寸的卡片已经画出来。
  captureReady('ready'),

  /// galLookupPresent 返回：卡片已贴到游戏画面（直接合成或位图帧已投递）。
  presented('present');

  const GalLookupLatencyStage(this.label);

  final String label;
}

/// 一次游戏内嵌查词的耗时记录。同一时刻最多一条在途（与查词本身的 latest-wins
/// 语义一致）：新的 submit 到达时，旧记录以 `superseded` 收尾。
class GalLookupLatencyTrace {
  GalLookupLatencyTrace._({
    required this.seq,
    required this.publishQpcUs,
    required this.dispatchQpcUs,
    required this.receivedUs,
    required this.cold,
  });

  /// 测试可替换的时钟（QPC 微秒）。
  static int Function() clock = () => Timeline.now;

  /// 测试可替换的输出（默认写 glog）。
  static void Function(String line) sink = glog;

  static GalLookupLatencyTrace? _active;
  static bool _sawFirstLookup = false;

  /// 当前在途的记录；没有时为 null。
  static GalLookupLatencyTrace? get active => _active;

  /// 收到一次 submit 命中：开一条新记录。
  static GalLookupLatencyTrace begin(GalLookupHit hit) {
    _active?._finish('superseded');
    final GalLookupLatencyTrace trace = GalLookupLatencyTrace._(
      seq: hit.seq,
      publishQpcUs: hit.publishQpcUs,
      dispatchQpcUs: hit.dispatchQpcUs,
      receivedUs: clock(),
      cold: !_sawFirstLookup,
    );
    _sawFirstLookup = true;
    _active = trace;
    return trace;
  }

  /// 在当前记录上打一个时刻；同一阶段只记第一次（例如尺寸会报多次，要的是首帧）。
  static void mark(GalLookupLatencyStage stage, {String? detail}) {
    _active?._mark(stage, detail);
  }

  /// 以 [outcome] 收尾当前记录并写出一行。
  static void finish(String outcome) {
    _active?._finish(outcome);
  }

  /// 会话重置（测试用）：忘记「本会话第一次查词」。
  static void resetForTesting() {
    _active = null;
    _sawFirstLookup = false;
    clock = () => Timeline.now;
    sink = glog;
  }

  final int seq;
  final int publishQpcUs;
  final int dispatchQpcUs;
  final int receivedUs;

  /// 本会话（本进程）的第一次查词：WebView 与词典都可能是冷的。
  final bool cold;

  final Map<GalLookupLatencyStage, int> _marks = <GalLookupLatencyStage, int>{};
  final List<String> _details = <String>[];
  bool _done = false;

  void _mark(GalLookupLatencyStage stage, String? detail) {
    if (_done || _marks.containsKey(stage)) return;
    _marks[stage] = clock();
    if (detail != null && detail.isNotEmpty) _details.add(detail);
  }

  void _finish(String outcome) {
    if (_done) return;
    _done = true;
    if (identical(_active, this)) _active = null;
    sink(format(outcome));
  }

  /// 一行摘要：总耗时（从 hook 发布算起；量不到发布时刻时从 Dart 收到算起）+ 逐段耗时。
  String format(String outcome) {
    final StringBuffer out = StringBuffer('gal-latency seq=$seq $outcome');
    if (cold) out.write(' cold');
    final int? last = _marks.isEmpty
        ? null
        : _marks.values.reduce((int a, int b) => a > b ? a : b);
    final bool hasPublish = publishQpcUs > 0 && publishQpcUs <= receivedUs;
    final int origin = hasPublish ? publishQpcUs : receivedUs;
    if (last != null) {
      out.write(' total=${_ms(last - origin)}');
      out.write(hasPublish ? '(from-hook)' : '(from-dart)');
    }
    out.write(' |');
    if (hasPublish) {
      final bool hasDispatch =
          dispatchQpcUs >= publishQpcUs && dispatchQpcUs <= receivedUs;
      if (hasDispatch) {
        out.write(' hook→poll=${_ms(dispatchQpcUs - publishQpcUs)}');
        out.write(' poll→dart=${_ms(receivedUs - dispatchQpcUs)}');
      } else {
        out.write(' hook→dart=${_ms(receivedUs - publishQpcUs)}');
      }
    }
    int previous = receivedUs;
    for (final GalLookupLatencyStage stage in GalLookupLatencyStage.values) {
      final int? at = _marks[stage];
      if (at == null) continue;
      out.write(' ${stage.label}=${_ms(at - previous)}');
      previous = at;
    }
    if (_details.isNotEmpty) out.write(' | ${_details.join(' ')}');
    return out.toString();
  }

  static String _ms(int micros) => (micros / 1000).toStringAsFixed(1);
}

/// 宿主页随首个 overlaySize 回报的分段（box.perf，单位毫秒，相对 renderStack 收到
/// 这次查词）：脚本注入完、根卡首次 popupRendered、尺寸上报。格式化成一段明细；
/// 不是预期形状就返回 null（旧宿主页 / 非首个 overlaySize）。
String? galLookupHostPerfDetail(Object? perf) {
  if (perf is! Map) return null;
  String part(String key) {
    final Object? value = perf[key];
    return value is num && value >= 0 ? value.round().toString() : '-';
  }

  return 'js[inject=${part('inject')} render=${part('render')} '
      'measure=${part('measure')}]';
}

/// 宿主页随 captureReady 回报的握手明细（args[3]）：arm → 第一个 rAF、arm → 放行的
/// 毫秒数，以及放行路径（`raf` = 两帧都画了，`timer` = rAF 停摆走了兜底计时器）。
String? galLookupCaptureReadyPerfDetail(Object? perf) {
  if (perf is! Map) return null;
  String part(String key) {
    final Object? value = perf[key];
    return value is num && value >= 0 ? value.round().toString() : '-';
  }

  final Object? by = perf['by'];
  return 'arm[raf1=${part('raf1')} ready=${part('ready')} '
      'by=${by is String ? by : '-'}]';
}
