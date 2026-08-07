// TODO-817 M1c / TODO-1274 来源库管理对话框：本文件只剩**对话框外壳**——列表、
// 添加/扫描/移除/重排的全部行为住在 [MediaSourcesView]（`media_sources_view.dart`），
// 与库页三视图里的「来源」视图（[MediaSourcesPage]）共用同一份实现。
//
// 保留本对话框入口的原因：视频页等处仍以「页头按钮 → 弹框管理」的既有交互暴露来源
// 管理，逐像素不变（Never break userspace）；新的页面入口只是多一条路进同一间屋子。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/utils.dart';

/// 管理网络/本地来源库的对话框：按 mediaKind（'video' | 'book' | 'manga'）过滤。
class MediaSourcesDialog extends ConsumerStatefulWidget {
  const MediaSourcesDialog({required this.mediaKind, super.key});

  /// 'video' | 'book' | 'manga' —— 决定统计文案与 mediaKind 过滤。
  final String mediaKind;

  @override
  ConsumerState<MediaSourcesDialog> createState() => _MediaSourcesDialogState();
}

class _MediaSourcesDialogState extends ConsumerState<MediaSourcesDialog> {
  /// 页脚「添加来源」要触发的是**内容体**里的流程（选本地文件夹 / 填网络表单 →
  /// 落库 → 立即扫描）。内容体自己不画这个按钮（页面语境把它放页头），所以外壳
  /// 经 key 调它的公开方法，而不是把整套添加流程复制一份到外壳里。
  final GlobalKey<MediaSourcesViewState> _viewKey =
      GlobalKey<MediaSourcesViewState>();

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double maxHeight =
        (MediaQuery.of(context).size.height * 0.55).clamp(160.0, 480.0);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.media_source_manage_title,
        leadingIcon: Icons.folder_copy_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: double.maxFinite,
            maxHeight: maxHeight,
          ),
          // 整体可滚动：HibikiReorderableColumn 自身不带滚动（内部 Stack + Column.min），
          // 来源多到超过 maxHeight 时会 RenderFlex 底部溢出、且下方行无法滚动查看
          // （BUG-445；TODO-1389：桌面最小窗高降到 480 后 maxHeight 被 clamp 到 ~242px，
          // ≥4 条来源即触发）。外层套 SingleChildScrollView：内容超高时整体滚动而非溢出，
          // 行少时仍按内容收缩。与同款「本地音频来源」对话框
          // （local_audio_sources_dialog）一致修法——此前独漏此层。
          child: SingleChildScrollView(
            child: MediaSourcesView(
              key: _viewKey,
              mediaKind: widget.mediaKind,
            ),
          ),
        ),
        // BUG-1184：这是全仓唯一一个还用 Row 的 [HibikiModalSheetFrame] 页脚（其余
        // 十几处都已是 Wrap），窄屏对话框里两个按钮相加就会溢出。与其余页脚对齐。
        footer: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => _viewKey.currentState?.addSource(),
              child: Text(t.media_source_add),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    );
  }
}
