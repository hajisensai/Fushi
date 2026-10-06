import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/utils.dart';

/// 整页形态的标签选择器（深链 / 旧调用点兼容）。主体与 [showTagPicker] 的 sheet /
/// 弹层是**同一个** [TagPickerPanel]：搜索、一键新建、已选 input chip、filter
/// chip 云、即时落库。新调用点一律用 [showTagPicker]。
class TagPickerPage extends StatelessWidget {
  /// 两种目标二选一，共用同一标签池：媒体条目传 [media]（统一媒体身份
  /// [MediaRef]：epub=bookKey / srt=SrtBooks.uid / video=bookUid /
  /// game=galgames.id）；合集传 [collectionId]（media_collections 主键）。
  const TagPickerPage({
    this.media,
    this.collectionId,
    super.key,
  }) : assert(
          (media != null) ^ (collectionId != null),
          'exactly one of: media / collectionId',
        );
  final MediaRef? media;
  final int? collectionId;

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.tag_label,
      // 不铺到页头底下：正文是与 sheet 共用的 [TagPickerPanel]，它自带固定的
      // 弹层标题行与底部动作行（FushiModalSheetFrame），只有中段可滚——内容
      // 无法滚到浮动页头底下，叠放只会让固定标题行压在页头里。
      extendBodyBehindHeader: false,
      body: SafeArea(
        child: TagPickerPanel(
          embedded: true,
          targets: TagTargets(
            media: <MediaRef>[if (media != null) media!],
            collectionIds: <int>[if (collectionId != null) collectionId!],
          ),
        ),
      ),
    );
  }
}
