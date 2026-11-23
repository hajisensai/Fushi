/// 从别处带着现场打开反馈提交页时的预填（[FeedbackComposePrefill]）。
///
/// 单独成叶子文件：要预填的一方（如复习库升级恢复页的报告动作）只依赖这个值类型，
/// 打开提交页的函数由上层注入，不必为了一个值类型 import 反馈页面簇（它们在 import
/// 大环里，`test/build/import_cycle_guard_test.dart`）。
library;

import 'dart:io';

import 'package:fushi_engine/feedback/feedback_models.dart';

/// 从别处带着现场打开提交页（例如复习库升级没通过核对：分类、标题、正文预填好，诊断报告作样本文件自动附上，
/// 用户不用自己去私有目录里找文件——手机上也找不到）。与 `FeedbackReopenSeed` 一样不读写草稿：草稿属于用户自己写到
/// 一半的那条新反馈，不能被预填内容覆盖，提交后也不能被顺手删掉。
class FeedbackComposePrefill {
  const FeedbackComposePrefill({
    required this.category,
    required this.title,
    required this.body,
    this.files = const <File>[],
  });

  final FeedbackCategory category;
  final String title;
  final String body;

  /// 自动附上的样本文件（按 `feedbackFileProblem` 过滤，超出 [FeedbackLimits.files] 的不附）。
  final List<File> files;
}
