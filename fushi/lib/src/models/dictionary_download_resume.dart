import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 词典下载的**导入配方**（BUG-3887 续）：随跨进程可接管的下载一起持久化
/// （[DictionaryDownloadHandoff.payload]），iOS 进程被系统回收、新进程接回下载后，
/// 据此走与原流程同一条导入调用——推荐词典初装，或以某本已装词典为显式替换目标的
/// 更新（手动更新 / 启动自动更新 / 控制通道 `dict update`）。
@immutable
class DictionaryImportRecipe {
  /// 推荐词典初装（[sourceOverride] 见 `recommendedDictionarySourceOverride`）。
  const DictionaryImportRecipe.install({
    required this.name,
    required this.sourceOverride,
  }) : replaceTargetName = null,
       forceReplaceExisting = false;

  /// 以已装词典 [replaceTargetName]（`Dictionary.name`）为替换目标重导。
  /// [forceReplaceExisting] 照抄原流程那次 `importDictionary` 调用（手动更新不传 = false，
  /// 自动更新传 true）。
  const DictionaryImportRecipe.update({
    required this.name,
    required String this.replaceTargetName,
    required this.sourceOverride,
    this.forceReplaceExisting = false,
  });

  static const String _kind = 'dictionaryImport';
  static const int _version = 1;

  /// 进度 / 结果文案里的词典名。
  final String name;

  /// 更新时被替换的那本（`Dictionary.name`）；初装为 null。
  final String? replaceTargetName;

  /// 原样传给 `AppModel.importDictionary` 的同名参数。
  final bool forceReplaceExisting;
  final Map<String, String> sourceOverride;

  Map<String, Object?> toPayload() => <String, Object?>{
    'kind': _kind,
    'v': _version,
    'name': name,
    if (replaceTargetName != null) 'replaceTarget': replaceTargetName,
    'force': forceReplaceExisting,
    'sourceOverride': sourceOverride,
  };

  /// 解析 [toPayload] 的产物；不认识的形态返回 null（= 没人接得住）。
  static DictionaryImportRecipe? fromPayload(Map<String, Object?> payload) {
    if (payload['kind'] != _kind || payload['v'] != _version) return null;
    final Object? name = payload['name'];
    final Object? target = payload['replaceTarget'];
    final Object? force = payload['force'];
    final Object? override = payload['sourceOverride'];
    if (name is! String || force is! bool || override is! Map) return null;
    if (target != null && target is! String) return null;
    if (override.entries.any(
      (MapEntry<Object?, Object?> e) => e.key is! String || e.value is! String,
    )) {
      return null;
    }
    final Map<String, String> sourceOverride = override.cast<String, String>();
    return target is String
        ? DictionaryImportRecipe.update(
            name: name,
            replaceTargetName: target,
            sourceOverride: sourceOverride,
            forceReplaceExisting: force,
          )
        : DictionaryImportRecipe.install(
            name: name,
            sourceOverride: sourceOverride,
          );
  }
}

/// 真正执行导入（`AppModel.importDictionary` 的那一刀）。
typedef DictionaryRecipeImporter =
    Future<void> Function({
      required File file,
      required ValueNotifier<String> progressNotifier,
      required DictionaryImportRecipe recipe,
      required Dictionary? replaceTarget,
    });

/// **纯函数**：一条接回来的下载 → 下完怎么导入。返回 null = 没人要了：
/// 配方解析不了，或要替换的那本词典已经不在库里（用户在进程死后删了它——这时再导入
/// 等于凭空装回一本被删的词典）。
ResumableDictionaryImport? resumableDictionaryImportFor({
  required DictionaryDownloadHandoff handoff,
  required Iterable<Dictionary> installed,
  required DictionaryRecipeImporter importer,
}) {
  final DictionaryImportRecipe? recipe = DictionaryImportRecipe.fromPayload(
    handoff.payload,
  );
  if (recipe == null) return null;
  Dictionary? target;
  final String? targetName = recipe.replaceTargetName;
  if (targetName != null) {
    for (final Dictionary d in installed) {
      if (d.name == targetName) {
        target = d;
        break;
      }
    }
    if (target == null) return null;
  }
  return ResumableDictionaryImport(
    name: recipe.name,
    importFile: (DictionaryDownloadJob job, File file) async {
      await importer(
        file: file,
        progressNotifier: job.message,
        recipe: recipe,
        replaceTarget: target,
      );
      return DictionaryDownloadOutcome(
        message: target != null
            ? t.dict_update_done(name: recipe.name)
            : t.dict_import_success_summary(n: 1),
        severity: ToastSeverity.success,
      );
    },
  );
}
