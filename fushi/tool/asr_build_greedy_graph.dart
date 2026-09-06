/// 开发/CI 工具：用 `buildAsrGreedyGraph` 把 decoder/joiner ONNX 拼成贪心解码
/// Loop 图并落盘，供 `tool/asr/verify_greedy_graph.py` 用 onnxruntime 对拍。
///
/// 用法（在 `fushi/` 下）：
///
/// ```text
/// dart run tool/asr_build_greedy_graph.dart \
///   --decoder <decoder.onnx> --joiner <joiner.onnx> --out <greedy.onnx> \
///   --blank 0 --unk 5222 [--context-size 2]
/// ```
///
/// 只依赖 `dart:io` 与纯 Dart 的 `onnx_proto` / `asr_greedy_graph`，不拉 Flutter。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/asr/asr_greedy_graph.dart';

void main(List<String> args) {
  final Map<String, String> opts = _parseArgs(args);
  final String decoderPath = _require(opts, 'decoder');
  final String joinerPath = _require(opts, 'joiner');
  final String outPath = _require(opts, 'out');
  final int blank = _requireInt(opts, 'blank');
  final int unk = _requireInt(opts, 'unk');
  final int contextSize = opts.containsKey('context-size')
      ? _requireInt(opts, 'context-size')
      : 2;

  final Uint8List decoder = File(decoderPath).readAsBytesSync();
  final Uint8List joiner = File(joinerPath).readAsBytesSync();
  final Stopwatch sw = Stopwatch()..start();
  final Uint8List graph = buildAsrGreedyGraph(
    decoderOnnx: decoder,
    joinerOnnx: joiner,
    blankId: blank,
    unkId: unk,
    contextSize: contextSize,
  );
  sw.stop();
  File(outPath).writeAsBytesSync(graph);
  stdout.writeln(
    'wrote $outPath (${graph.length} bytes, build ${sw.elapsedMilliseconds} ms)',
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

int _requireInt(Map<String, String> opts, String key) {
  final int? v = int.tryParse(_require(opts, key));
  if (v == null) _usage('--$key 不是整数：${opts[key]}');
  return v;
}

Never _usage(String reason) {
  stderr.writeln(reason);
  stderr.writeln(
    '用法：dart run tool/asr_build_greedy_graph.dart --decoder <onnx> '
    '--joiner <onnx> --out <onnx> --blank <id> --unk <id> [--context-size 2]',
  );
  exit(64);
}
