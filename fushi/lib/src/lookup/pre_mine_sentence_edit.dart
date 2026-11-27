import 'dart:convert';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningRequestOverrides;
import 'package:material_ui/material_ui.dart';

/// 反馈 uEnwXmBIR0（用户拍板：先做各应用外入口共用的「制卡前编辑例句」，截图和音频
/// 照带）。
///
/// 应用外查词卡（桌面覆盖窗：热键 / 截屏识字 / galgame 台词浮窗 / 网页视频 / 悬浮
/// 字幕；Android 查词窗）在「+」旁给一颗「编辑例句后制卡」：popup.js 经
/// `fushiPopupMineEntryByIndex(idx, {editSentence: true})` 回点同一颗「+」，标记随
/// payload 的 `miningOverrides` 上来。宿主在派发给制卡路径（默认路径或表面自己的
/// 制卡委托）**之前**弹编辑框，用户改完的句子写回 `fields['sentence']` 并打上
/// [kEditedMineSentenceKey]——委托里的截图 / 句子音频照旧由委托自己带，一样不少。

/// popup.js 随 `miningOverrides` 带上来的「先编辑例句」标记。
const String kPreMineSentenceEditKey = 'editSentence';

/// 宿主写进 fields 的「这句是用户手改的例句」标记：自己算句子的制卡委托（galgame
/// 台词浮窗按台词行取句）据此改用 `fields['sentence']`。
const String kEditedMineSentenceKey = 'sentenceEdited';

/// 弹出编辑框：[sentence] 是这张卡本来要用的例句；返回改好的句子，null = 放弃制卡。
typedef PreMineSentenceEditor = Future<String?> Function(String sentence);

/// 用户手改过的例句（[applyPreMineSentenceEdit] 写进去的）；没改过为 null。
String? editedMineSentenceOf(Map<String, String> fields) =>
    fields[kEditedMineSentenceKey] == '1' ? fields['sentence'] : null;

/// 这次请求要不要先编辑例句（payload 的 `miningOverrides` 里带了 [kPreMineSentenceEditKey]）。
bool preMineSentenceEditRequested(Map<String, String> fields) =>
    _overridesJson(fields)?[kPreMineSentenceEditKey] == true;

/// 处理「先编辑例句」：没请求就原样返回 [fields]；请求了就先把标记从 `miningOverrides`
/// 里摘掉（其余覆盖项——例如「调整句子音频」拖出的起止——原样保留），再用 [editor]
/// 编辑 [initialSentence]。返回 null = 用户在编辑框里放弃，这张卡不制。
///
/// [editor] 为 null（宿主给不出编辑界面）时只摘标记、照常制卡，不吞掉这次点击。
Future<Map<String, String>?> applyPreMineSentenceEdit(
  Map<String, String> fields, {
  required String initialSentence,
  required PreMineSentenceEditor? editor,
}) async {
  final Map<String, Object?>? overrides = _overridesJson(fields);
  if (overrides == null || overrides[kPreMineSentenceEditKey] != true) {
    return fields;
  }
  final Map<String, String> out = Map<String, String>.of(fields);
  overrides.remove(kPreMineSentenceEditKey);
  if (overrides.isEmpty) {
    out.remove(MiningRequestOverrides.wireKey);
  } else {
    out[MiningRequestOverrides.wireKey] = jsonEncode(overrides);
  }
  if (editor == null) return out;
  final String? edited = await editor(initialSentence);
  if (edited == null) return null;
  out['sentence'] = edited;
  out[kEditedMineSentenceKey] = '1';
  return out;
}

Map<String, Object?>? _overridesJson(Map<String, String> fields) {
  final String? raw = fields[MiningRequestOverrides.wireKey];
  if (raw == null || raw.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

/// 编辑框本体（Flutter 对话框）：桌面由宿主借主窗弹，Android 查词窗就地弹。
/// 返回 null = 取消；空句子不许确认（要不带例句就别点这颗按钮）。
Future<String?> showPreMineSentenceEditor(
  BuildContext context,
  String sentence,
) => showFushiTextInputDialog(
  context: context,
  title: t.popup_sentence_edit_title,
  initialValue: sentence,
  confirmLabel: t.popup_cross_app_audio_mine,
  maxLines: 6,
  keyboardType: TextInputType.multiline,
);

/// 测试用：直接构造带「先编辑例句」标记的 fields。
@visibleForTesting
Map<String, String> debugFieldsRequestingSentenceEdit(
  Map<String, String> fields, {
  Map<String, Object?> otherOverrides = const <String, Object?>{},
}) => <String, String>{
  ...fields,
  MiningRequestOverrides.wireKey: jsonEncode(<String, Object?>{
    ...otherOverrides,
    kPreMineSentenceEditKey: true,
  }),
};
