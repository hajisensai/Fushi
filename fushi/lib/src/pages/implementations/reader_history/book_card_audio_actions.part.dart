// 书卡（小说 / 漫画）长按 / 右键菜单里的有声入口。
//
// 拍板 Ew0AxAgycu 方案 a（设计稿 a-import-first）：手里已有成品有声文件的人最多，
// 「导入」是主入口、放最上面；「制作」（小说的有声书工作室 / 漫画的有声漫画工作台）
// 紧随其后、同为工作台级，两者都不再进「更多」。第一项画主色，其余同级项画中性色
// （[DialogWorkbenchAction.emphasized]）。
//
// 只管菜单构建（顺序、层级、外观主次）；各入口点下去走的仍是原来的流程，回调由
// 书架页传进来。合集详情页的成员卡复用同一份书卡菜单（BUG-2969），所以两边一致。
//
// 独立成 part 而非单独的库：它要用 [DialogWorkbenchAction]（media_item_dialog_page
// 在 lib/ 的 import 大环里），单独成库会让大环多一个文件
// （test/build/import_cycle_guard_test.dart）。
part of '../reader_fushi_history_page.dart';

/// 按「导入在上、制作紧随」排好的有声工作台入口；回调为 null 的入口不出现。
///
/// * [importAudiobook]：小说「导入有声书」（按正文匹配字幕的导入对话框）；
/// * [makeAudiobook]：小说「制作有声书」（TTS 有声书工作室）；
/// * [importMangaAudio]：漫画「导入漫画有声」（选成品清单登记，与工作台里
///   「导入漫画有声」步骤同一个函数）；
/// * [openMangaWorkbench]：有声漫画工作台，[mangaWorkbenchStatus] 是它的进度副行。
List<DialogWorkbenchAction> bookCardAudioWorkbenchActions({
  VoidCallback? importAudiobook,
  VoidCallback? makeAudiobook,
  VoidCallback? importMangaAudio,
  VoidCallback? openMangaWorkbench,
  Future<String?> Function()? mangaWorkbenchStatus,
}) {
  final List<DialogWorkbenchAction> actions = <DialogWorkbenchAction>[];
  void add(
    String label,
    IconData icon,
    VoidCallback onPressed, {
    String? subtitle,
    Future<String?> Function()? loadStatus,
  }) => actions.add(
    DialogWorkbenchAction(
      label: label,
      icon: icon,
      subtitle: subtitle,
      loadStatus: loadStatus,
      onPressed: onPressed,
      // 只有排在最上面的那一项画主色。
      emphasized: actions.isEmpty,
    ),
  );

  // 导入在上（主入口）。
  if (importAudiobook != null) {
    add(t.audiobook_import, Icons.headphones_outlined, importAudiobook);
  }
  if (importMangaAudio != null) {
    add(t.manga_audio_import, FushiIcons.importFile, importMangaAudio);
  }
  // 制作紧随（同级）。
  if (makeAudiobook != null) {
    add(t.audiobook_studio_title, FushiIcons.voice, makeAudiobook);
  }
  if (openMangaWorkbench != null) {
    add(
      t.manga_audio_workbench_title,
      Icons.headphones_outlined,
      openMangaWorkbench,
      subtitle: t.manga_audio_workbench_not_started,
      loadStatus: mangaWorkbenchStatus,
    );
  }
  return actions;
}
