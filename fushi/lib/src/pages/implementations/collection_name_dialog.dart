import 'package:flutter/material.dart';

import 'package:fushi/src/pages/implementations/name_input_dialog.dart';
import 'package:fushi/src/pages/implementations/series_shelf_card.dart';
import 'package:fushi/utils.dart';

/// 统一合集 UI v2 Phase E：合集命名/重命名对话框（原 series_detail_page 的
/// `showSeriesNameDialog`，随死掉的 SeriesDetailPage 整页删除迁居至此）。
/// 供「组合成合集」「合集重命名」共用；[previewCovers] 非空时铺成员封面缩略预览。
///
/// 弹窗壳本身已收敛进通用的 [showNameInputDialog]（库内全部改名入口共用一份）；
/// 这里只剩合集专属的两处差异：书签图标和封面网格预览头部。
Future<String?> showCollectionNameDialog({
  required BuildContext context,
  required String title,
  String initialName = '',
  List<Widget> previewCovers = const <Widget>[],
}) {
  return showNameInputDialog(
    context: context,
    title: title,
    labelText: t.series_name_hint,
    initialName: initialName,
    leadingIcon: Icons.collections_bookmark_outlined,
    header: previewCovers.isEmpty
        ? null
        : _CollectionCoverPreview(covers: previewCovers),
  );
}

/// TODO-947：多选「组合成合集」命名弹窗里，把选中的前 N 本封面铺成手机文件夹式
/// 网格缩略预览，让用户在命名/确认时就直观看到「我把哪几本合并进去了」。
class _CollectionCoverPreview extends StatelessWidget {
  const _CollectionCoverPreview({required this.covers});

  final List<Widget> covers;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Center(
      child: SizedBox(
        width: 92,
        height: 120,
        child: FushiCard(
          padding: EdgeInsets.zero,
          margin: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: tokens.radii.cardRadius,
            child: SeriesFolderCover(covers: covers),
          ),
        ),
      ),
    );
  }
}
