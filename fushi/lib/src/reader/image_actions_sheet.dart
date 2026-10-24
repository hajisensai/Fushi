/// 长按图片的全局动作面板：阅读器正文（WebView 内长按）、缩放看图、阅读器与
/// 书架端插图册、歌词模式插图——凡是「长按一张磁盘上的图片」都走这一个面板，
/// 面板里的动作本体也各只有一份（保存 = [saveImageFileWithFeedback]，分享 =
/// [shareImageFile]，复制 = [copyImageFileToClipboard]）。宿主只负责把图解析成
/// [File]。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/reader/illustration_zoom_viewer.dart'
    show copyImageFileToClipboard, shareImageFile;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/image_file_saver.dart';
import 'package:fushi/utils.dart';

/// 面板里可能出现的动作。
enum ImageAction { save, share, copy }

/// 纯函数：某个操作系统上面板列哪些动作（顺序即显示顺序，保存永远第一）。
/// - 手机 / macOS：保存 + 系统分享；
/// - Windows：保存 + 复制到剪贴板（原生 `copyImageFile` channel 只在 Windows 注册）；
/// - Linux：只有保存（share_plus 在 Linux 没有注册）。
List<ImageAction> imageActionsFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS =>
        const <ImageAction>[ImageAction.save, ImageAction.share],
      TargetPlatform.windows => const <ImageAction>[
        ImageAction.save,
        ImageAction.copy,
      ],
      _ => const <ImageAction>[ImageAction.save],
    };

/// 弹出长按图片面板并执行用户选中的动作；返回选中的动作（关掉面板 = null）。
/// [platform] 只给测试用，生产按真实操作系统取。
Future<ImageAction?> showImageActionsSheet(
  BuildContext context, {
  required File file,
  TargetPlatform? platform,
}) async {
  final List<ImageAction> actions = imageActionsFor(
    platform ?? defaultTargetPlatformForImageSave(),
  );
  final ImageAction? picked = await adaptiveModalSheet<ImageAction>(
    context: context,
    isScrollControlled: false,
    builder: (BuildContext sheetContext) =>
        ImageActionsSheet(fileName: p.basename(file.path), actions: actions),
  );
  if (picked != null) await runImageAction(picked, file);
  return picked;
}

/// 执行一个动作（面板之外的入口，例如 Windows 右键菜单，也走这里）。
Future<void> runImageAction(ImageAction action, File file) => switch (action) {
  ImageAction.save => saveImageFileWithFeedback(file),
  ImageAction.share => shareImageFile(file),
  ImageAction.copy => copyImageFileToClipboard(file),
};

/// 面板本体：分段卡列表、错峰进场；点一项就带着它关面板。
class ImageActionsSheet extends StatelessWidget {
  const ImageActionsSheet({
    required this.fileName,
    required this.actions,
    super.key,
  });

  final String fileName;
  final List<ImageAction> actions;

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      title: t.reader_image_actions_title,
      subtitle: fileName,
      leadingIcon: FushiIcons.image,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < actions.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: FushiGroupedListItem(
                  index: i,
                  count: actions.length,
                  child: FushiListItem(
                    key: ValueKey<String>('image_action_${actions[i].name}'),
                    autofocus: i == 0,
                    leading: FushiListLeadingIcon(
                      _iconOf(actions[i]),
                      shape: i == 0
                          ? FushiLeadingShape.cookie
                          : FushiLeadingShape.circle,
                      tone: i == 0
                          ? FushiCardTone.primary
                          : FushiCardTone.secondary,
                    ),
                    title: Text(_labelOf(actions[i])),
                    onTap: () => Navigator.of(context).pop(actions[i]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _iconOf(ImageAction action) => switch (action) {
    ImageAction.save => FushiIcons.download,
    ImageAction.share => FushiIcons.share,
    ImageAction.copy => FushiIcons.copy,
  };

  static String _labelOf(ImageAction action) => switch (action) {
    ImageAction.save => t.reader_image_save,
    ImageAction.share => t.reader_image_share,
    ImageAction.copy => t.reader_copy_image,
  };
}
