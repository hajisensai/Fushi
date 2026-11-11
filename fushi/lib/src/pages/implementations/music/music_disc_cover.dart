/// 光盘专辑的「真盘」封面（用户 2026-11-11：CD / BD 学 galgame 音乐鉴赏那样画成
/// 真封面）：专辑封面印在盘面上（中心透明夹持环 + 轴孔 + 银边），网格卡底下一条
/// 深色盒面写盘的规格与专辑信息。盒面只写库里真有的字段（规格取自登记的盘种，
/// 标题 / 副行与普通专辑卡同一来源），不编号、不印商标字样。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 盘种在盒面 / 盘上的短标（与 `MusicDiscBadge` 同一口径：CD / DVD / BD）。
String musicDiscKindLabel(MusicDiscKind? kind) => switch (kind) {
  MusicDiscKind.cdda => 'CD',
  MusicDiscKind.dvd => 'DVD',
  MusicDiscKind.bluray => 'BD',
  null => '',
};

/// 盘面上轴孔半径占盘半径的比例（真实 CD：15 mm 孔 / 120 mm 盘）。
const double kMusicDiscHoleFraction = 0.125;

/// 透明夹持区外缘占盘半径的比例（真实 CD 夹持区到 Ø 33 mm 上下，印刷面从约
/// Ø 40 mm 开始）。
const double kMusicDiscHubFraction = 0.34;

/// 悬停时盘转过的圈数。
const double kMusicDiscHoverTurns = 0.08;

/// 印着封面的一张盘。[hovering] 时转一个小角度（时长走动效令牌，系统关动画时
/// 直接到位）。
class MusicDiscFace extends StatelessWidget {
  const MusicDiscFace({super.key, required this.cover, this.hovering = false});

  /// 印在盘面上的图（专辑封面；会被裁成圆环，调用方不用自己裁圆角）。
  final Widget cover;
  final bool hovering;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: AnimatedRotation(
          turns: hovering ? kMusicDiscHoverTurns : 0,
          duration: fushiMotionDuration(context, FushiMotion.long),
          curve: Curves.easeOutCubic,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ClipPath(clipper: const _DiscRingClipper(), child: cover),
              const IgnorePointer(
                child: CustomPaint(painter: _DiscSurfacePainter()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 盘面形状：整圆减去中心轴孔（偶奇填充），孔里透出页面底。
class _DiscRingClipper extends CustomClipper<Path> {
  const _DiscRingClipper();

  @override
  Path getClip(Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: c, radius: r))
      ..addOval(Rect.fromCircle(center: c, radius: r * kMusicDiscHoleFraction));
  }

  @override
  bool shouldReclip(covariant _DiscRingClipper oldClipper) => false;
}

/// 盘面上压在封面之上的物理细节：两道扇形反光、透明夹持环（磨砂灰 + 一圈压痕）、
/// 轴孔描边、外缘银边。
class _DiscSurfacePainter extends CustomPainter {
  const _DiscSurfacePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    final Rect box = Rect.fromCircle(center: c, radius: r);

    // 扇形反光（只在印刷面，不盖夹持环）。
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const SweepGradient(
          colors: <Color>[
            Color(0x00FFFFFF),
            Color(0x26FFFFFF),
            Color(0x00FFFFFF),
            Color(0x00FFFFFF),
            Color(0x1CFFFFFF),
            Color(0x00FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: <double>[0.04, 0.11, 0.18, 0.54, 0.6, 0.66, 1],
        ).createShader(box),
    );

    // 透明夹持区：半透明浅灰盖住封面中心，外缘一道浅亮边。
    final double hub = r * kMusicDiscHubFraction;
    final double hole = r * kMusicDiscHoleFraction;
    final Path hubRing = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: c, radius: hub))
      ..addOval(Rect.fromCircle(center: c, radius: hole));
    canvas.drawPath(hubRing, Paint()..color = const Color(0xA6C9CDD4));
    // 夹持区里的压痕环（叠片环）。
    canvas.drawCircle(
      c,
      hub * 0.66,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.025
        ..color = const Color(0x668A8F99),
    );
    canvas.drawCircle(
      c,
      hub,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.012
        ..color = const Color(0x99E8EAEE),
    );
    // 轴孔内壁。
    canvas.drawCircle(
      c,
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.03
        ..color = const Color(0xFF2A2A2E),
    );

    // 外缘：一道银边 + 内侧一道细亮线。
    canvas.drawCircle(
      c,
      r - r * 0.012,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.024
        ..color = const Color(0xCCE6E8EE),
    );
    canvas.drawCircle(
      c,
      r * 0.955,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x1FFFFFFF),
    );
  }

  @override
  bool shouldRepaint(covariant _DiscSurfacePainter oldDelegate) => false;
}

/// 盒面的固定色：盒子是实物，不随主题换色（与盘面银边同理）。
const Color kMusicDiscCaseColor = Color(0xFF1D1C20);

/// 网格里的一张光盘专辑：上面是印着封面的盘，底下一条深色盒面压住盘的下沿，写
/// 规格 | 标题 / 副行。总高填满网格格子（方形封面区 + 文字块高，与普通专辑卡
/// 同一行高）。
class MusicDiscCaseCard extends StatelessWidget {
  const MusicDiscCaseCard({
    super.key,
    required this.cover,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.hovering = false,
  });

  final Widget cover;
  final MusicDiscKind? kind;
  final String title;
  final String subtitle;
  final bool hovering;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : w * 1.22;
        // 盒面压住方形封面区底部一截，盘露出约八成。
        final double caseHeight = (h - w) + w * 0.16;
        final double disc = w * 0.9;
        return SizedBox(
          width: w,
          height: h,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: (w - disc) / 2,
                top: w * 0.02,
                width: disc,
                height: disc,
                child: MusicDiscFace(cover: cover, hovering: hovering),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: caseHeight,
                child: _DiscCaseStrip(
                  kindLabel: musicDiscKindLabel(kind),
                  title: title,
                  subtitle: subtitle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DiscCaseStrip extends StatelessWidget {
  const _DiscCaseStrip({
    required this.kindLabel,
    required this.title,
    required this.subtitle,
  });

  final String kindLabel;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kMusicDiscCaseColor,
        borderRadius: BorderRadius.circular(6),
        border: const Border(top: BorderSide(color: Color(0xFF3A3940))),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: <Widget>[
            if (kindLabel.isNotEmpty) ...<Widget>[
              Text(
                kindLabel,
                style: text.titleSmall?.copyWith(
                  color: const Color(0xFFEDEDF0),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              Container(
                width: 1,
                height: 24,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: const Color(0xFFCFCFD6),
              ),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(
                      color: const Color(0xFFF2F2F4),
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: const Color(0xFFA5A2AE),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
