/// 镜台一帧要画的东西（与后端无关）：[DioramaScene.step] 跑完状态机、相机、音频代用品与
/// 栅格缓存后产出它（[DioramaRenderFrame]），再交给 Flutter GPU 渲染器（真 3D）或 Canvas 后备实现（2.5D）去画。
///
/// 两个后端吃同一份数据，所以状态机 / 运镜 / 跟唱包络只有一份实现。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_particles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_text_raster.dart';

/// 一块文字平面取栅格里的哪张图。
enum DioramaRasterLayer {
  /// 整行白字图（邻行）。
  line,

  /// 当前行逐单元图集（字身 / 灵魂出窍副本）。
  units,

  /// 同布局的模糊图集（辉光）。
  glow,
}

/// folia 的 three.js `renderOrder`：透明物体先按它排，再由远到近。
abstract final class DioramaRenderOrder {
  static const int neighbor = 0;
  static const int unitGlow = 17;
  static const int unitSoul = 18;
  static const int unitBase = 19;
}

/// 世界里的一块带贴图的平面。
///
/// 栅格像素坐标（y 向下）里的点 p 落在世界 `world + right * ((p.x - anchor.x) * scale) +
/// up * (-(p.y - anchor.y) * scale)`；[src] 是贴图里取的矩形，[dst] 是它在栅格坐标里摆的位置
/// （灵魂出窍会把 dst 抬高、放大，普通平面 dst == src）。
class DioramaPlane {
  const DioramaPlane({
    required this.raster,
    required this.layer,
    required this.src,
    required this.dst,
    required this.anchor,
    required this.world,
    required this.right,
    required this.up,
    required this.scale,
    required this.color,
    required this.alpha,
    required this.additive,
    required this.depthTest,
    required this.cpuFog,
    required this.renderOrder,
    required this.sortDepth,
  });

  final DioramaLineRaster raster;
  final DioramaRasterLayer layer;
  final ui.Rect src;
  final ui.Rect dst;
  final ui.Offset anchor;
  final DioramaVec world;
  final DioramaVec right;
  final DioramaVec up;

  /// 每栅格像素的世界单位。
  final double scale;

  /// 染色（不含透明度）。
  final ui.Color color;

  /// 透明度（不含雾；雾由后端各自处理）。
  final double alpha;

  /// 叠加混合（辉光 / 灵魂出窍）。
  final bool additive;

  /// 参与深度测试（folia：邻行是，当前行不是——它永远不被阵列挡住）。
  final bool depthTest;

  /// Canvas 后备实现按距离线性淡出（它没有逐片元雾；GPU 用 three 的线性雾）。
  final bool cpuFog;

  final int renderOrder;

  /// 到相机的距离（同 renderOrder 内由远到近排序用）。
  final double sortDepth;
}

/// 背景尘埃。
class DioramaMotesDraw {
  const DioramaMotesDraw({
    required this.positions,
    required this.revision,
    required this.ox,
    required this.oy,
    required this.oz,
    required this.color,
    required this.alpha,
    required this.sizeWorld,
  });

  /// 世界坐标 xyz 连排（环形槽，内容按行增量重写）。
  final Float32List positions;

  /// [positions] 每改一次加一（GPU 端据此决定要不要重传）。
  final int revision;

  /// 整片漂移。
  final double ox;
  final double oy;
  final double oz;
  final ui.Color color;
  final double alpha;
  final double sizeWorld;
}

/// 点云阵列 / 长廊。
class DioramaParticlesDraw {
  const DioramaParticlesDraw({
    required this.geometry,
    required this.pool,
    required this.frame,
    required this.palette,
  });

  final DioramaParticleGeometry geometry;
  final DioramaRipplePool pool;
  final DioramaParticleFrame frame;

  /// 主色 / 强调色 / 次色（已按背景拉够对比）。
  final List<ui.Color> palette;
}

/// 一帧。
class DioramaRenderFrame {
  const DioramaRenderFrame({
    required this.camera,
    required this.fogColor,
    required this.motes,
    required this.particles,
    required this.planes,
  });

  final DioramaCamera camera;

  /// 阻尼后的背景色（three 场景雾色）。
  final ui.Color fogColor;
  final DioramaMotesDraw? motes;
  final DioramaParticlesDraw? particles;

  /// 按 Canvas 后备实现的绘制顺序排列；GPU 端按 [DioramaPlane.renderOrder] 再稳定排序。
  final List<DioramaPlane> planes;
}
