import 'package:cupertino_ui/cupertino_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// SF Symbols 自带数字的 ±N 秒字形（`gobackward.N` / `goforward.N`）覆盖的秒数。
const List<int> kVideoAppleNumberedSeekSeconds = <int>[
  10,
  15,
  30,
  45,
  60,
  75,
  90,
];

/// [seconds] 对应的 SF 带数字字形；SF 没有该数字时返回 null（调用方改画无数字圆箭头 +
/// 叠字）。纯函数，[VideoAppleSeekGlyph] 与测试同源调用。
IconData? videoAppleNumberedSeekIcon({
  required bool forward,
  required int seconds,
}) {
  switch (seconds) {
    case 10:
      return forward
          ? CupertinoIcons.goforward_10
          : CupertinoIcons.gobackward_10;
    case 15:
      return forward
          ? CupertinoIcons.goforward_15
          : CupertinoIcons.gobackward_15;
    case 30:
      return forward
          ? CupertinoIcons.goforward_30
          : CupertinoIcons.gobackward_30;
    case 45:
      return forward
          ? CupertinoIcons.goforward_45
          : CupertinoIcons.gobackward_45;
    case 60:
      return forward
          ? CupertinoIcons.goforward_60
          : CupertinoIcons.gobackward_60;
    case 75:
      return forward
          ? CupertinoIcons.goforward_75
          : CupertinoIcons.gobackward_75;
    case 90:
      return forward
          ? CupertinoIcons.goforward_90
          : CupertinoIcons.gobackward_90;
  }
  return null;
}

/// Apple 设计系统（AVKit 风格）视频控制条的 ±N 秒跳转字形：圆箭头里写着跳转秒数。
///
/// 只服务 Apple / Cupertino 分支（M3E 分支是「快退图标 + `−Ns` 文字标注」，在视频页
/// `_seekLabelButtonContent` 里画），所以不分两套设计系统。SF 有现成数字字形的秒数
/// （[kVideoAppleNumberedSeekSeconds]）直接用它；其余秒数（长步进可配 5–300 秒）画
/// 无数字的 `gobackward` / `goforward` 圆箭头，再在圆心叠一个等宽数字，长相与 SF 字形
/// 一致、秒数随配置变化。
class VideoAppleSeekGlyph extends StatelessWidget {
  const VideoAppleSeekGlyph({
    super.key,
    required this.forward,
    required this.seconds,
    required this.size,
    required this.color,
    this.semanticLabel,
  });

  final bool forward;
  final int seconds;
  final double size;
  final Color color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final IconData? numbered = videoAppleNumberedSeekIcon(
      forward: forward,
      seconds: seconds,
    );
    if (numbered != null) {
      return FushiIcon(
        numbered,
        size: size,
        color: color,
        semanticLabel: semanticLabel,
      );
    }
    final String digits = '$seconds';
    // 圆箭头内圈直径约为字形尺寸的一半；三位数时再缩一档，免得压到箭头描边。
    final double fontSize = size * (digits.length >= 3 ? 0.26 : 0.32);
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            FushiIcon(
              forward ? CupertinoIcons.goforward : CupertinoIcons.gobackward,
              size: size,
              color: color,
            ),
            Padding(
              // SF 圆箭头的圆心比字形框中心略偏下（顶部留给箭头尖）。
              padding: EdgeInsets.only(top: size * 0.08),
              child: Text(
                digits,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  height: 1.0,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: color,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
