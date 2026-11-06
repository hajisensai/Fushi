// 排程内核 FFI 调用开销基准：统计页对每张卡算一次可提取度，这里量 N 张卡的耗时。
//
//   FUSHI_FSRS_LIB=<绝对路径>/fushi_fsrs.dll dart run benchmark/fsrs_ffi_bench.dart [卡数]
//
// 三行逐张调用拆开开销来源：version = 纯 FFI + JSON 往返；validate = 往返 + 建模型；
// retrievability = 完整一次调用。batch 行是一次调用算完全部卡。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:fushi_srs/fushi_srs.dart';

void main(List<String> args) {
  final int n = args.isEmpty ? 50000 : int.parse(args.first);
  final FfiFsrsEngine? engine = FfiFsrsEngine.tryCreate(
    libraryPath: Platform.environment['FUSHI_FSRS_LIB'],
  );
  if (engine == null) {
    stderr.writeln('native library not found');
    exitCode = 1;
    return;
  }
  for (final SrsAlgorithm alg in SrsAlgorithm.values) {
    final List<double> params = engine.defaultParams(alg);
    final List<SrsMemory> memories = <SrsMemory>[
      for (int i = 0; i < n; i++)
        SrsMemory(stability: 1 + i % 300, difficulty: 1 + i % 9),
    ];
    final List<double> elapsed = <double>[
      for (int i = 0; i < n; i++) (i % 120) + 0.25,
    ];
    stdout.writeln('${alg.wire} · $n cards');
    final String versionReq = jsonEncode(<String, Object?>{'op': 'version'});
    final String validateReq = jsonEncode(<String, Object?>{
      'op': 'validate',
      'algorithm': alg.wire,
      'params': params,
    });
    _time('  version × n', () {
      for (int i = 0; i < n; i++) {
        _raw(engine, versionReq);
      }
    });
    _time('  validate × n', () {
      for (int i = 0; i < n; i++) {
        _raw(engine, validateReq);
      }
    });
    _time('  retrievability × n', () {
      for (int i = 0; i < n; i++) {
        engine.retrievability(
          algorithm: alg,
          params: params,
          memory: memories[i],
          elapsedDays: elapsed[i],
        );
      }
    });
    _time('  retrievabilityBatch', () {
      engine.retrievabilityBatch(
        algorithm: alg,
        params: params,
        memories: memories,
        elapsedDays: elapsed,
      );
    });
  }
}

/// 只做 FFI 往返（不含 Dart 侧的请求编码），用来把建模型与 JSON 的开销拆开。
void _raw(FfiFsrsEngine engine, String request) {
  final Pointer<Char> req = request.toNativeUtf8().cast<Char>();
  try {
    final Pointer<Char> resp = engine.library.bindings.ffsrs_call(req);
    jsonDecode(resp.cast<Utf8>().toDartString());
    engine.library.bindings.ffsrs_free_string(resp);
  } finally {
    calloc.free(req);
  }
}

void _time(String label, void Function() body) {
  final Stopwatch sw = Stopwatch()..start();
  body();
  sw.stop();
  stdout.writeln('$label: ${sw.elapsedMilliseconds} ms');
}
