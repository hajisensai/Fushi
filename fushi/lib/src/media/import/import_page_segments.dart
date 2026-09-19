import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 导入页顶部分段选择器的四段：一段一种信息，正文只渲染当前段。
///
/// 视频与漫画的「导入」视图共用这一套段（2026-09-19 用户口径：「统一一下视频
/// 和动画的导入页，对源和仓库的 UI 上下拖动感觉可以在上面弄个多段选择器，不同
/// 类型信息分开」）。此前两页把本地来源、扩展仓库、扩展目录、在线源四种东西
/// 竖着串成一整页长滚动（漫画 1900+ 条扩展目录夹在中间），用户要找「仓库」得
/// 从扩展目录里翻过去。
///
/// - [local]：快速导入 + 常驻来源（扫描根）；
/// - [stores]：扩展仓库（Mihon 仓库地址 / Aidoku 仓库）的增删改与刷新；
/// - [extensions]：仓库里可装的扩展目录 + 已装扩展的启停 / 卸载；
/// - [sources]：扩展提供的在线源（启停 / 排序 / 登录 / 偏好 / 清数据）。
enum ImportPageSegment { local, stores, extensions, sources }

/// [ImportPageSegment] 的显示名。
String importPageSegmentLabel(ImportPageSegment segment) => switch (segment) {
  ImportPageSegment.local => t.media_import_segment_local,
  ImportPageSegment.stores => t.media_import_segment_stores,
  ImportPageSegment.extensions => t.media_import_segment_extensions,
  ImportPageSegment.sources => t.media_import_segment_sources,
};

IconData _segmentIcon(ImportPageSegment segment) => switch (segment) {
  ImportPageSegment.local => Icons.folder_outlined,
  ImportPageSegment.stores => Icons.hub_outlined,
  ImportPageSegment.extensions => Icons.extension_outlined,
  ImportPageSegment.sources => Icons.public,
};

/// 导入页的分段选择器：横向铺满、单选。
///
/// 窄于 [_kIconLabelMinWidth] 时只画文字（四段带图标在手机竖屏会挤爆），宽屏
/// 图标 + 文字。只有一段时不该出现——调用方按 `segments.length > 1` 决定挂不挂。
class ImportPageSegmentBar extends StatelessWidget {
  const ImportPageSegmentBar({
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// 本页可用的段（按显示顺序）。
  final List<ImportPageSegment> segments;
  final ImportPageSegment selected;
  final ValueChanged<ImportPageSegment> onChanged;

  static const double _kIconLabelMinWidth = 480;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool showIcons = constraints.maxWidth >= _kIconLabelMinWidth;
        final List<ButtonSegment<ImportPageSegment>> buttonSegments =
            <ButtonSegment<ImportPageSegment>>[
              for (final ImportPageSegment segment in segments)
                ButtonSegment<ImportPageSegment>(
                  value: segment,
                  icon: showIcons ? Icon(_segmentIcon(segment)) : null,
                  label: Text(
                    importPageSegmentLabel(segment),
                    key: ValueKey<String>('import_segment_${segment.name}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ];
        void select(Set<ImportPageSegment> values) {
          if (values.isEmpty || values.first == selected) return;
          onChanged(values.first);
        }

        if (isCupertinoPlatform(context)) {
          return SizedBox(
            width: double.infinity,
            child: adaptiveSegmentedButton<ImportPageSegment>(
              context: context,
              segments: buttonSegments,
              selected: <ImportPageSegment>{selected},
              onSelectionChanged: select,
            ),
          );
        }
        return SegmentedButton<ImportPageSegment>(
          showSelectedIcon: false,
          // 铺满可用宽度、各段等宽：这是页面级的视图切换，不是行内的小开关。
          expandedInsets: EdgeInsets.zero,
          segments: buttonSegments,
          selected: <ImportPageSegment>{selected},
          onSelectionChanged: select,
        );
      },
    );
  }
}
