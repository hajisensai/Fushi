import 'package:flutter/material.dart';

import 'package:fushi/src/pages/implementations/series_shelf_card.dart';
import 'package:fushi/utils.dart';

/// 统一合集 UI v2 Phase E：合集命名/重命名对话框（原 series_detail_page 的
/// `showSeriesNameDialog`，随死掉的 SeriesDetailPage 整页删除迁居至此）。
/// 供「组合成合集」「合集重命名」共用；[previewCovers] 非空时铺成员封面缩略预览。
Future<String?> showCollectionNameDialog({
  required BuildContext context,
  required String title,
  String initialName = '',
  List<Widget> previewCovers = const <Widget>[],
}) {
  return showAppDialog<String>(
    context: context,
    builder: (_) => _CollectionNameDialog(
      title: title,
      initialName: initialName,
      previewCovers: previewCovers,
    ),
  );
}

class _CollectionNameDialog extends StatefulWidget {
  const _CollectionNameDialog({
    required this.title,
    required this.initialName,
    this.previewCovers = const <Widget>[],
  });

  final String title;
  final String initialName;

  /// TODO-947：多选「组合成合集」命名弹窗里，把选中的前 N 本封面铺成手机文件夹式
  /// 网格缩略预览，让用户在命名/确认时就直观看到「我把哪几本合并进去了」。空则不渲染。
  final List<Widget> previewCovers;

  @override
  State<_CollectionNameDialog> createState() => _CollectionNameDialogState();
}

class _CollectionNameDialogState extends State<_CollectionNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: widget.title,
        leadingIcon: Icons.collections_bookmark_outlined,
        // TODO-1389：外层 HibikiDialogFrame(maxHeightFactor:0.74, scrollable:false) 给有界
        // 高度；body 是含 92x120 封面大图 + 输入框的非滚动 Column，最小窗高 480（客户区
        // ≈440）下会顶破 0.74 界底部溢出（尤其更大字号 / 紧凑间距）。scrollable:true 提供
        // 滚动兜底，矮窗可滚不溢出。
        scrollable: true,
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
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.previewCovers.isNotEmpty) ...<Widget>[
              Center(
                child: SizedBox(
                  width: 92,
                  height: 120,
                  child: HibikiCard(
                    padding: EdgeInsets.zero,
                    margin: EdgeInsets.zero,
                    child: ClipRRect(
                      borderRadius: tokens.radii.cardRadius,
                      child: SeriesFolderCover(covers: widget.previewCovers),
                    ),
                  ),
                ),
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
            HibikiTextField(
              controller: _controller,
              labelText: t.series_name_hint,
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: _submit,
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}
