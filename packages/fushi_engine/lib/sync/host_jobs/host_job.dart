/// 通用 host 任务的数据模型与 wire 编码。
///
/// 设计 docs/specs/2026-09-08-fushi-server-headless-design.md §3.4：
/// `pending → uploading → running → done | error | cancelled`（与远程 OCR 作业
/// 同一状态机；wire 值即枚举名）。每个任务落一个目录：
///
/// ```
/// <jobRoot>/<id>/job.json        任务记录（本文件的 JSON 形态，重启可续）
/// <jobRoot>/<id>/inputs/<name>   客户端上传的输入
/// <jobRoot>/<id>/outputs/<name>  runner 产物
/// ```
///
/// 输入还可以是 host 本地已有的同内容文件（[HostJobRecord.hostInputs]）：客户端先发
/// 内容哈希清单（`POST /api/jobs/<id>/inputs/match`），命中的那份不上传、直接读 host
/// 本地路径；跑前跑后各核对一次内容，变了就以 [kHostInputChangedError] 失败，客户端
/// 据此回退为整份上传。
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

/// 输入匹配用的内容哈希算法（`/api/capabilities` 的 `jobs.inputMatch`）。
const String kHostInputMatchAlgorithm = 'sha256';

/// host 本地输入在任务开始前 / 结束后内容变了（或被删）：任务以这个前缀的 error
/// 失败，客户端看到就不再复用 host 文件、整份重新上传。
const String kHostInputChangedError = 'host_input_changed';

/// 输入名只允许一段文件名：去路径、去 `..`、空则给默认名。客户端与 host 用同一
/// 规则，客户端据此预先算出 host 上的输入名（匹配清单与上传路径要对得上）。
String hostJobInputName(String raw) {
  final String base = p.basename(raw.replaceAll('\\', '/')).trim();
  final String cleaned = base.replaceAll(RegExp(r'[^\w.\-() ]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'input';
  return cleaned;
}

/// 命中的 host 本地输入：匹配时刻的内容指纹（跑前跑后据此核对）。
class HostInputRef {
  const HostInputRef({
    required this.path,
    required this.sha256,
    required this.size,
    required this.modifiedAt,
  });

  factory HostInputRef.fromJson(Map<String, dynamic> json) => HostInputRef(
        path: json['path'] as String,
        sha256: json['sha256'] as String,
        size: json['size'] as int,
        modifiedAt: json['modifiedAt'] as int,
      );

  /// host 本机绝对路径（不出现在 wire 上）。
  final String path;
  final String sha256;
  final int size;
  final int modifiedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'sha256': sha256,
        'size': size,
        'modifiedAt': modifiedAt,
      };
}

enum HostJobState { pending, uploading, running, done, error, cancelled }

class HostJobRecord {
  HostJobRecord({
    required this.id,
    required this.kind,
    required this.params,
    required this.createdAt,
    required this.updatedAt,
    this.state = HostJobState.pending,
    this.progress = 0,
    this.message,
    this.error,
    Map<String, String>? outputs,
    List<String>? inputs,
    Map<String, HostInputRef>? hostInputs,
    this.primaryOutput,
  })  : outputs = outputs ?? <String, String>{},
        inputs = inputs ?? <String>[],
        hostInputs = hostInputs ?? <String, HostInputRef>{};

  factory HostJobRecord.fromJson(Map<String, dynamic> json) => HostJobRecord(
        id: json['id'] as String,
        kind: json['kind'] as String,
        params: Map<String, Object?>.from(json['params'] as Map? ?? const {}),
        createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
        state: HostJobState.values.byName(json['state'] as String),
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        message: json['message'] as String?,
        error: json['error'] as String?,
        outputs: Map<String, String>.from(json['outputs'] as Map? ?? const {}),
        inputs: List<String>.from(json['inputs'] as List? ?? const []),
        hostInputs: <String, HostInputRef>{
          for (final MapEntry<Object?, Object?> e
              in (json['hostInputs'] as Map? ?? const {}).entries)
            e.key.toString(): HostInputRef.fromJson(
              Map<String, dynamic>.from(e.value! as Map),
            ),
        },
        primaryOutput: json['primaryOutput'] as String?,
      );

  final String id;
  final String kind;
  final Map<String, Object?> params;
  final DateTime createdAt;
  DateTime updatedAt;
  HostJobState state;

  /// 0..1；runner 报进度用。
  double progress;
  String? message;
  String? error;

  /// 产物名 → 相对 `outputs/` 的文件名。
  final Map<String, String> outputs;

  /// 已上传的输入名（相对 `inputs/`）。
  final List<String> inputs;

  /// 输入名 → 命中的 host 本地文件（不上传、直接读）。同名后来又上传了就从这里删掉。
  final Map<String, HostInputRef> hostInputs;

  /// `GET /api/jobs/<id>/result` 不带名字时返回的产物名。
  String? primaryOutput;

  bool get isTerminal =>
      state == HostJobState.done ||
      state == HostJobState.error ||
      state == HostJobState.cancelled;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind,
        'params': params,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'state': state.name,
        'progress': progress,
        if (message != null) 'message': message,
        if (error != null) 'error': error,
        'outputs': outputs,
        'inputs': inputs,
        if (hostInputs.isNotEmpty)
          'hostInputs': <String, Object?>{
            for (final MapEntry<String, HostInputRef> e in hostInputs.entries)
              e.key: e.value.toJson(),
          },
        if (primaryOutput != null) 'primaryOutput': primaryOutput,
      };

  /// 给客户端的轮询视图（与 OCR 作业的 `{state, ...}` 同形，多带 progress/outputs）。
  Map<String, Object?> toWireJson() => <String, Object?>{
        'id': id,
        'kind': kind,
        'state': state.name,
        'progress': progress,
        if (message != null) 'message': message,
        if (error != null) 'error': error,
        'outputs': outputs.keys.toList(growable: false),
        if (primaryOutput != null) 'primaryOutput': primaryOutput,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}
