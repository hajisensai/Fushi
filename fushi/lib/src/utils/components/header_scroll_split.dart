import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

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
    this.topInset = 0,
  });

  final Key scrollKey;
  final Widget header;
  final List<Widget> resultSlivers;

  /// [header] 上方的让位（页面正文铺到浮动页头底下时的页头下沿）。窄屏它是
  /// 滚动内容的一部分（头部随结果滚进页头底下），宽屏垫在固定头部上方。
  final double topInset;

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
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: topInset),
              child: header,
            ),
          ),
          ...resultSlivers,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(top: topInset),
          child: header,
        ),
        Expanded(
          child: CustomScrollView(key: scrollKey, slivers: resultSlivers),
        ),
      ],
    );
  }
}
