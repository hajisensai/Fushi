/// 开发/CI 工具：用 `convertAsrModelToFp16` 把 fp32 ONNX 整图转成 fp16 并落盘，
/// 供 `tool/asr/verify_fp16_encoder.py` 用 onnxruntime-directml 对拍吞吐与偏差。
///
/// 用法（在 `fushi/` 下）：
///
/// ```text
/// dart run tool/asr_convert_fp16.dart --in <encoder.onnx> --out <encoder.fp16.onnx>
/// ```
///
/// 只依赖 `dart:io` 与纯 Dart 的 `onnx_proto` / `asr_fp16_graph`，不拉 Flutter。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/asr/asr_fp16_graph.dart';

void main(List<String> args) {
  final Map<String, String> opts = _parseArgs(args);
  final String inPath = _require(opts, 'in');
  final String outPath = _require(opts, 'out');

  final Uint8List source = File(inPath).readAsBytesSync();
  final Stopwatch sw = Stopwatch()..start();
  final Uint8List converted = convertAsrModelToFp16(source);
  sw.stop();
  File(outPath).writeAsBytesSync(converted);
  stdout.writeln(
    'wrote $outPath (${source.length} -> ${converted.length} bytes, '
    'convert ${sw.elapsedMilliseconds} ms)',
  );
}

/// 解析 `--key value` 形式的参数；重复或缺值直接报错退出。
Map<String, String> _parseArgs(List<String> args) {
  final Map<String, String> out = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (!a.startsWith('--')) _usage('意外的参数 "$a"');
    if (i + 1 >= args.length) _usage('$a 缺值');
    final String key = a.substring(2);
    if (out.containsKey(key)) _usage('$a 重复');
    out[key] = args[++i];
  }
  return out;
}

String _require(Map<String, String> opts, String key) {
  final String? v = opts[key];
  if (v == null || v.isEmpty) _usage('缺 --$key');
  return v;
}

Never _usage(String reason) {
  stderr.writeln(reason);
  stderr.writeln(
    '用法：dart run tool/asr_convert_fp16.dart --in <onnx> --out <onnx>',
  );
  exit(64);
}
