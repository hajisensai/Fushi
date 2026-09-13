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
library;

import 'dart:convert';

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
    this.primaryOutput,
  })  : outputs = outputs ?? <String, String>{},
        inputs = inputs ?? <String>[];

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
