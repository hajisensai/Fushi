import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';

/// 用户明确勾选「记住这些选择」后，删除确认框下次采用的两个默认值。
///
/// 这是一个整体偏好：两个破坏性选择必须在同一行里原子读写，不能出现只记住一半的
/// 中间状态。记录不存在就表示「不记住」，两项都回到安全默认值 false。
class DeletePromptRememberedChoices {
  const DeletePromptRememberedChoices({
    required this.syncEverywhere,
    required this.deleteLocalFiles,
  });

  final bool syncEverywhere;
  final bool deleteLocalFiles;
}

/// 删除确认框「记住这些选择」的设备偏好存储。
///
/// 单 JSON key 同时承载开关存在性与两个值：存在 = 记住，删除 = 忘记。某次弹窗因为
/// 没有同步通道或没有可删原件而隐藏其中一项时，UI 仍保留已加载的对应值，因此确认
/// 不会把暂时不可用的选择意外覆盖掉。
class DeletePromptPreferenceStore {
  const DeletePromptPreferenceStore(this._db);

  static const String prefKey = 'delete_prompt_remembered_choices';
  static const int _version = 1;

  final FushiDatabase _db;

  Future<DeletePromptRememberedChoices?> load() async {
    final String? raw = await _db.getPref(prefKey);
    if (raw == null) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['version'] != _version) {
        return null;
      }
      final Object? syncEverywhere = decoded['syncEverywhere'];
      final Object? deleteLocalFiles = decoded['deleteLocalFiles'];
      if (syncEverywhere is! bool || deleteLocalFiles is! bool) return null;
      return DeletePromptRememberedChoices(
        syncEverywhere: syncEverywhere,
        deleteLocalFiles: deleteLocalFiles,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> write(DeletePromptRememberedChoices? choices) async {
    if (choices == null) {
      await _db.deletePref(prefKey);
      return;
    }
    await _db.setPref(
      prefKey,
      jsonEncode(<String, Object>{
        'version': _version,
        'syncEverywhere': choices.syncEverywhere,
        'deleteLocalFiles': choices.deleteLocalFiles,
      }),
    );
  }
}
