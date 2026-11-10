import 'package:material_ui/material_ui.dart';

/// 字幕候选文件名的统一显示规则：**完整软换行、不限行、不截断**。
///
/// 字幕搜索的两处列表（文件视图 `SubtitleSearchPanel` 的结果行、版本视图
/// `SubtitleVersionGroupList` 的文件行）里，同一番的候选文件名前半段几乎一样
/// （组名 + 番名 + 集数 + 分辨率 + 编码），区分版本 / 集数的信息恰恰在**末尾**
/// （BUG-4323：横屏手机上两条 EP5 都截在「...HEVC-10bit AAC」，看不出差别；
/// TODO-673：同理集数被省略号吃掉）。任何行数上限在足够窄的宽度下都会再次切掉
/// 末尾，所以这里不设上限：两处列表都在可滚动的 ListView 里，行高自由，换行
/// 只会让该行变高，不会溢出。
///
/// 本组件自己重置 [DefaultTextStyle] 的 maxLines / overflow，不依赖调用点的
/// `FushiListItem.titleMaxLines`——否则 [Text] 的 maxLines 为 null 时会回落到
/// 父级 DefaultTextStyle 的行数上限（FushiListItem 默认 1 行 + ellipsis），
/// 规则又散回各调用点。
class SubtitleFileNameText extends StatelessWidget {
  const SubtitleFileNameText(this.fileName, {super.key});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final DefaultTextStyle parent = DefaultTextStyle.of(context);
    return DefaultTextStyle(
      style: parent.style,
      textAlign: parent.textAlign,
      softWrap: true,
      // 不限行时不能带 ellipsis：TextPainter 在 maxLines 为 null 时把省略号
      // 作用于第一行，「不限行」会退化成单行。clip 在无上限时永不触发。
      overflow: TextOverflow.clip,
      maxLines: null,
      textWidthBasis: parent.textWidthBasis,
      textHeightBehavior: parent.textHeightBehavior,
      child: Text(fileName),
    );
  }
}
