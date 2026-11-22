import 'dart:developer' as developer;
import 'dart:isolate' show Isolate;

import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

/// 性能探针用：在 [body] 执行期间收 UI isolate 的 VM CPU 采样，按函数打印
/// 自身耗时（exclusive）与累计耗时（inclusive）前若干名。timeline 只看得到
/// widget build / layout 事件，看不到 FFI、同步 IO、DB 解码这类堵 UI 线程的
/// 同步工作；CPU 采样能直接指到函数。
Future<void> profileUiCpu(
  String tag,
  String label,
  Future<void> Function() body, {
  int top = 45,
}) async {
  final developer.ServiceProtocolInfo info = await developer.Service.getInfo();
  final Uri? http = info.serverUri;
  if (http == null) {
    debugPrint('[$tag] $label cpu: no vm service');
    await body();
    return;
  }
  final String ws = http
      .replace(
        scheme: 'ws',
        path: '${http.path.endsWith('/') ? http.path : '${http.path}/'}ws',
      )
      .toString();
  final vm.VmService service = _service ??= await vmServiceConnectUri(ws);
  try {
    final String isolateId = developer.Service.getIsolateId(Isolate.current)!;
    await service.clearCpuSamples(isolateId);
    final int t0 = (await service.getVMTimelineMicros()).timestamp!;
    await body();
    final int t1 = (await service.getVMTimelineMicros()).timestamp!;
    final vm.CpuSamples samples = await service.getCpuSamples(
      isolateId,
      t0,
      t1 - t0,
    );
    _report(tag, label, samples, top);
  } on Object catch (error) {
    debugPrint('[$tag] $label cpu failed: $error');
    _service = null;
  }
}

vm.VmService? _service;

void _report(String tag, String label, vm.CpuSamples s, int top) {
  final List<vm.ProfileFunction> fns = s.functions ?? <vm.ProfileFunction>[];
  final List<vm.CpuSample> samples = s.samples ?? <vm.CpuSample>[];
  final double periodMs = (s.samplePeriod ?? 1000) / 1000;
  String name(int i) {
    final Object? f = fns[i].function;
    String n;
    String owner = '';
    if (f is vm.FuncRef) {
      n = f.name ?? '?';
      final Object? o = f.owner;
      if (o is vm.ClassRef) owner = '${o.name}.';
      if (o is vm.FuncRef) owner = '${o.name}.';
    } else if (f is vm.NativeFunction) {
      n = 'native:${f.name}';
    } else {
      n = '$f';
    }
    final String uri = fns[i].resolvedUrl ?? '';
    final String file = uri.isEmpty ? '' : ' (${uri.split('/').last})';
    return '$owner$n$file';
  }

  final Map<int, int> self = <int, int>{};
  final Map<int, int> incl = <int, int>{};
  for (final vm.CpuSample sample in samples) {
    final List<int> stack = sample.stack ?? const <int>[];
    if (stack.isEmpty) continue;
    self[stack.first] = (self[stack.first] ?? 0) + 1;
    for (final int f in stack.toSet()) {
      incl[f] = (incl[f] ?? 0) + 1;
    }
  }
  debugPrint(
    '[$tag] $label cpu samples=${samples.length} '
    'period=${periodMs.toStringAsFixed(2)}ms',
  );
  List<MapEntry<int, int>> sorted(Map<int, int> m) =>
      m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final MapEntry<int, int> e in sorted(self).take(top)) {
    debugPrint(
      '[$tag] $label   self ${(e.value * periodMs).toStringAsFixed(1)}ms '
      '${name(e.key)}',
    );
  }
  // 累计榜只列应用代码（package:fushi* / fushi_engine / fushi_core），框架
  // 的 build/layout 外壳每个样本都在栈里，没有信息量。
  int shown = 0;
  for (final MapEntry<int, int> e in sorted(incl)) {
    final String uri = fns[e.key].resolvedUrl ?? '';
    if (!uri.contains('fushi')) continue;
    debugPrint(
      '[$tag] $label   incl ${(e.value * periodMs).toStringAsFixed(1)}ms '
      '${name(e.key)}',
    );
    if (++shown >= top) break;
  }
}
