/// 后台任务入口的一行数据（[BackgroundTask]）。
///
/// 从 `background_tasks_indicator.dart`（入口按钮 / 明细弹层 UI，读同步编排）拆出的叶子
/// 值类型：各任务源（互联下载、补刮……）只需把自己的状态折成 [BackgroundTask]，不该为此
/// import 整个入口 UI。原先 `interconnect_download_background_tasks → background_tasks_indicator`
/// 这条边把互联下载的任务映射拖进了 lib/ 最大 import 环
/// （`test/build/import_cycle_guard_test.dart`）。入口文件照旧 re-export 本文件。
library;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show IconData;

/// 一项正在后台跑的任务（给入口与明细弹层看的那一层）。
@immutable
class BackgroundTask {
  const BackgroundTask({
    required this.id,
    required this.icon,
    required this.line,
    this.fraction,
    this.onOpen,
    this.openLabel,
    this.detail,
    this.stageSince,
    this.errors = const <String>[],
    int? failureCount,
    this.finished = false,
  }) : _failureCount = failureCount;

  /// 稳定标识（明细行的 key）。
  final String id;
  final IconData icon;

  /// 一行描述，如「同步阅读数据 (27/36) 书名」。
  final String line;

  /// 明细弹层里的第二行：哪条通道、在等谁（反馈 kM-Gb_Xnu-）。null = 不显示。
  final String? detail;

  /// 当前这一步从何时开始（毫秒）；明细行据此实时显示「这一步已多久」，分得清
  /// 「在慢慢传」和「卡住了」。null = 不显示。
  final int? stageSince;

  /// 本轮记下的失败（每行一条，明细里可展开）。同因的多项可能合成一行，所以行数
  /// 不一定等于失败数，失败数见 [failureCount]。
  final List<String> errors;

  final int? _failureCount;

  /// 失败了几项（「N 项失败」的 N）。没另给时等于 [errors] 的行数。
  int get failureCount => _failureCount ?? errors.length;

  /// 这一轮已经结束、只是因为有失败才留在明细里。入口的进度环不画它。
  final bool finished;

  /// 0..1；null = 没有可测总数（不定态）。
  final double? fraction;

  /// 明细行尾的「去处理」动作（补刮任务面板）；null = 只展示。
  final VoidCallback? onOpen;
  final String? openLabel;

  @override
  bool operator ==(Object other) =>
      other is BackgroundTask &&
      other.id == id &&
      other.icon == icon &&
      other.line == line &&
      other.fraction == fraction &&
      other.openLabel == openLabel &&
      other.detail == detail &&
      other.stageSince == stageSince &&
      listEquals(other.errors, errors) &&
      other.failureCount == failureCount &&
      other.finished == finished;

  @override
  int get hashCode => Object.hash(
    id,
    icon,
    line,
    fraction,
    openLabel,
    detail,
    stageSince,
    Object.hashAll(errors),
    failureCount,
    finished,
  );
}
