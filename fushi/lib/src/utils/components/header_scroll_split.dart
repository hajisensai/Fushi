import 'package:material_ui/material_ui.dart';
import 'package:fushi/utils.dart';

/// 查询 / 筛选头部 + 结果 sliver 的统一滚动容器（反馈 XFsZIWYbr8）。
///
/// - 窄屏（与首页手机布局同一断点：按界面缩放折算后的真实窗口宽 < 600，
///   [WindowSizeClass.compact]）：[header] 作为首个 sliver 与结果同属一个滚动
///   视图，头部随结果上滑让出屏幕。
/// - 宽屏：[header] 固定在滚动区外，只有 [resultSlivers] 滚动。
///
/// 调用方需给出有界高度（如放进 `Expanded`）。
class HeaderScrollSplit extends StatelessWidget {
  const HeaderScrollSplit({
    super.key,
    required this.scrollKey,
    required this.header,
    required this.resultSlivers,
  });

  final Key scrollKey;
  final Widget header;
  final List<Widget> resultSlivers;

  /// 是否走手机（窄屏）布局。
  static bool isPhoneLayout(BuildContext context) =>
      windowSizeClassReal(
        MediaQuery.sizeOf(context).width,
        FushiAppUiScale.of(context),
      ) ==
      WindowSizeClass.compact;

  @override
  Widget build(BuildContext context) {
    if (isPhoneLayout(context)) {
      return CustomScrollView(
        key: scrollKey,
        slivers: <Widget>[
          SliverToBoxAdapter(child: header),
          ...resultSlivers,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        Expanded(
          child: CustomScrollView(key: scrollKey, slivers: resultSlivers),
        ),
      ],
    );
  }
}
