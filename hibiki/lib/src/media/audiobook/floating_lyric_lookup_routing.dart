// TODO-872 — 桌面悬浮歌词条点词 → 867 app 外全局查词覆盖窗的统一路由。
//
// 用户诉求：主窗最小化/被遮挡着听书时点悬浮字幕上的词，结果必须弹在 app 外
// （与 Ctrl+Alt+D 全局热键同款的 NOACTIVATE 覆盖窗、跟着光标），而不是弹进
// 看不见的主窗（in-app 弹窗 / 切主窗词典 tab）。两条桌面 Dart 路由（reader 在场
// 的 reader_hibiki/lyrics.part.dart 与 app 级 AppModel 默认 handler）共用本适配
// 器，分词共用同一把 [floatingLyricSearchTerm]，消除两处分词漂移。
//
// 平台边界：Android 的悬浮歌词 native overlay 自带 PopupDictActivity，点词根本
// 不回 Dart、不经过这里；[GlobalLookupController.isSupported]（Windows-only）为
// false 或控制器未 start 时本路由返回 false，由调用方回落各自原路由——点词永不
// 静默丢失。

import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/models/app_model.dart';

/// 桌面悬浮字幕条点词时，从整句文本与点击字符索引解析出真正要查的词
/// （TODO-376）。优先用语言分词器 Language.wordFromIndex 切出的 [word]；切不出
/// （空白 / 标点 / 引擎未就绪）则回退整句 [text]。两者皆空返回空串，调用方据此
/// no-op。顶层纯函数便于单测（原居 reader_hibiki_page.dart，TODO-872 随点词路由
/// 收拢至此）。
String floatingLyricSearchTerm({
  required String text,
  required int index,
  required String word,
}) {
  final String trimmedWord = word.trim();
  if (trimmedWord.isNotEmpty) return trimmedWord;
  return text.trim();
}

/// 悬浮歌词点词（[text] 整行 + [index] 命中字符）优先走 app 外全局查词覆盖窗
/// （TODO-872）。true = 覆盖窗已接手：卡片弹在光标处（native 条只回传
/// text+index、无坐标，而触发点击刚发生在光标下），整行文本作为卡片的句子横幅
/// 与制卡 sentence 字段。false = 覆盖窗不可用（非 Windows / 控制器未 start /
/// 分不出词），调用方回落自己原有路由。
Future<bool> tryFloatingLyricGlobalLookup({
  required AppModel appModel,
  required String text,
  required int index,
}) async {
  if (!GlobalLookupController.isSupported) {
    return false;
  }
  final String searchTerm = floatingLyricSearchTerm(
    text: text,
    index: index,
    word: JapaneseLanguage.instance.wordFromIndex(text: text, index: index),
  );
  if (searchTerm.isEmpty) {
    return false;
  }
  return GlobalLookupController.instance
      .lookupText(searchTerm, sentence: text.trim());
}
