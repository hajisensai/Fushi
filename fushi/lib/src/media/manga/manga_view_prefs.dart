/// 漫画阅读器「观看偏好」的值域与枚举（缩放范围、灵敏度、翻页动画、底色、点击
/// 翻页热区布局）。
///
/// 刻意做成**无依赖的叶子文件**：偏好仓库（`preferences_repository.dart`）、设置
/// schema、阅读器页面与 WebView 文档生成器四处都要用同一组边界值，此前这些数字
/// 被各自硬编码（`clamp(50, 200)` 在 Dart 侧 4 处 + JS 侧 2 处各写一遍），改一次
/// 范围要同步 6 个地方，漏一个就表现为「设置里能调到 400% 但阅读器里被打回 200%」。
library;

/// 漫画缩放百分比下限 / 上限（单一真相源）。
///
/// 上限从旧的 200% 提到 400%：200% 对高分屏上的小开本单页漫画根本不够（用户反馈
/// 「缩放极其不灵敏」的一半是这个天花板，而不是步长）。下限保持 50%。
const int kMangaZoomMinPercent = 50;
const int kMangaZoomMaxPercent = 400;

/// 缩放灵敏度倍率（百分比）。100 = 基准手感，越大滚轮/捏合每一步缩放越多。
const int kMangaZoomSensitivityMin = 25;
const int kMangaZoomSensitivityMax = 400;
const int kMangaZoomSensitivityDefault = 100;

/// 翻页动画样式。
///
/// 存字符串键而非 enum index：重排枚举不得破坏已落盘的偏好。
enum MangaPageAnimation { none, slide, fade }

extension MangaPageAnimationKey on MangaPageAnimation {
  String get key {
    switch (this) {
      case MangaPageAnimation.none:
        return 'none';
      case MangaPageAnimation.slide:
        return 'slide';
      case MangaPageAnimation.fade:
        return 'fade';
    }
  }

  /// 动画时长（毫秒）。`none` 恒 0，供 CSS `transition-duration` 直接使用。
  int get durationMs {
    switch (this) {
      case MangaPageAnimation.none:
        return 0;
      case MangaPageAnimation.slide:
        return 180;
      case MangaPageAnimation.fade:
        return 160;
    }
  }

  /// 未知值一律回落 [MangaPageAnimation.slide]（旧版本行为 = 有滑动过渡）。
  static MangaPageAnimation fromKey(String raw) {
    switch (raw) {
      case 'none':
        return MangaPageAnimation.none;
      case 'fade':
        return MangaPageAnimation.fade;
      case 'slide':
      default:
        return MangaPageAnimation.slide;
    }
  }
}

/// 阅读器底色。
///
/// 此前恒黑（`manga_overlay_html.dart` 的 `html,body{background:#000}` 与页面
/// `Scaffold.backgroundColor` 两处各硬编码一份）。黑底不是对所有页图都正确的选择：
/// 白底四格/扫描版彩页在黑底上会沿页边切出一圈高对比亮线，而墨水屏用户要的恰恰
/// 是白底。存字符串键而非 enum index：重排枚举不得破坏已落盘的偏好。
enum MangaBackground { black, white, gray, theme }

extension MangaBackgroundKey on MangaBackground {
  String get key {
    switch (this) {
      case MangaBackground.black:
        return 'black';
      case MangaBackground.white:
        return 'white';
      case MangaBackground.gray:
        return 'gray';
      case MangaBackground.theme:
        return 'theme';
    }
  }

  /// 固定底色的 CSS 值；[MangaBackground.theme] 没有固定值（随应用主题走），返回
  /// null，由调用方用当时的主题色补上。
  ///
  /// 灰用 `#2b2b2b`：比纯黑低一档对比，长时间阅读眼睛负担小，又不会像中灰那样和
  /// 漫画网点撞色。
  String? get fixedCss {
    switch (this) {
      case MangaBackground.black:
        return '#000';
      case MangaBackground.white:
        return '#fff';
      case MangaBackground.gray:
        return '#2b2b2b';
      case MangaBackground.theme:
        return null;
    }
  }

  /// 未知值一律回落 [MangaBackground.black]（旧版本行为 = 黑底）。
  static MangaBackground fromKey(String raw) {
    switch (raw) {
      case 'white':
        return MangaBackground.white;
      case 'gray':
        return MangaBackground.gray;
      case 'theme':
        return MangaBackground.theme;
      case 'black':
      default:
        return MangaBackground.black;
    }
  }
}

/// 四个新偏好的默认值（单一真相源）。
///
/// 偏好仓库与 [AppModel] 两侧都要它：后者在 `_prefsRepo` 未就绪（弹窗词典 / 悬浮
/// 查词这两个不经 `initialise()` 的 entry point）时要回落到**逐字相同**的默认值，
/// 各写一份字面量就会出现「改了默认只改到一半」。
const String kMangaBackgroundDefault = 'black';
const String kMangaTapZoneLayoutDefault = 'left_right';
const int kMangaSpreadOffsetDefault = 1;
const bool kMangaWidePageSoloDefault = true;

/// AI 分镜逐格导航默认关闭：模型需用户主动下载，且普通翻页行为保持兼容。
const bool kMangaPanelNavigationDefault = false;

/// 点击翻页的区域布局。
///
/// 旧实现只有一种：左右各占 25% 宽的竖条（[MangaTapZoneLayout.leftRight]），中间
/// 留白不翻页。单手持握手机时够不到对侧边缘，横屏平板上那条又太窄——Mihon 因此给
/// 了四种预设，这里对齐同一组语义。
enum MangaTapZoneLayout {
  leftRight,
  lShaped,
  kindle,
  topBottom,
  defaultZones,
  edge,
  disabled,
}

extension MangaTapZoneLayoutKey on MangaTapZoneLayout {
  String get key {
    switch (this) {
      case MangaTapZoneLayout.leftRight:
        return 'left_right';
      case MangaTapZoneLayout.lShaped:
        return 'l_shaped';
      case MangaTapZoneLayout.kindle:
        return 'kindle';
      case MangaTapZoneLayout.topBottom:
        return 'top_bottom';
      case MangaTapZoneLayout.defaultZones:
        return 'default';
      case MangaTapZoneLayout.edge:
        return 'edge';
      case MangaTapZoneLayout.disabled:
        return 'disabled';
    }
  }

  /// 未知值一律回落 [MangaTapZoneLayout.leftRight]（旧版本行为）。
  static MangaTapZoneLayout fromKey(String raw) {
    switch (raw) {
      case 'l_shaped':
        return MangaTapZoneLayout.lShaped;
      case 'kindle':
        return MangaTapZoneLayout.kindle;
      case 'top_bottom':
        return MangaTapZoneLayout.topBottom;
      case 'default':
        return MangaTapZoneLayout.defaultZones;
      case 'edge':
        return MangaTapZoneLayout.edge;
      case 'disabled':
        return MangaTapZoneLayout.disabled;
      case 'right_left':
      case 'left_right':
      default:
        return MangaTapZoneLayout.leftRight;
    }
  }
}

/// 点击翻页热区：视口归一化矩形（0..1）+ 命中后前进还是后退。
///
/// 刻意做成**数据**而不是判定函数：注入 WebView 的 JS 只做「遍历矩形、命中即回调」
/// 这一件事，几何与阅读方向镜像全在 Dart 侧算好并被单测钉住。旧的 `_tapZoneTurn`
/// 把阈值、镜像和布局揉在 JS 字符串里，改一处只能靠人眼读注入后的脚本验证。
class MangaTapZone {
  const MangaTapZone({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.forward,
  });

  /// 归一化视口坐标（左上原点，0..1）。
  final double left;
  final double top;
  final double width;
  final double height;

  /// true = 前进（`next`），false = 后退（`prev`）。**已经**按阅读方向镜像过，
  /// 消费方不得再镜像一次。
  final bool forward;

  bool contains(double x, double y) =>
      x >= left && x < left + width && y >= top && y < top + height;
}

/// 归一化的边缘条宽度：左右布局的竖条、L 型的下横条厚度、Kindle 的窄条都用它。
const double kMangaTapZoneEdge = 0.25;

/// 生成某个布局下的热区表。
///
/// [rtl] 为日漫右开本：视觉上「左边 = 下一页」。镜像只翻转 [MangaTapZone.forward]，
/// 不动几何——几何是手指够不够得到的问题，与阅读方向无关。
///
/// 语义（以 LTR 描述，RTL 自动镜像）：
///  * [MangaTapZoneLayout.leftRight]：左竖条后退 / 右竖条前进，中间不翻页（旧行为）。
///  * [MangaTapZoneLayout.lShaped]：右竖条 + 下横条前进，左竖条后退。单手横握时拇指
///    自然落在下沿，不必够到对侧。
///  * [MangaTapZoneLayout.kindle]：左窄条后退，其余整片前进（含中央）。翻页最省力，
///    代价是中央点击不再留给「唤出界面 / 双击缩放」。
///  * [MangaTapZoneLayout.topBottom]：上半后退 / 下半前进。竖屏单手与 webtoon 点击
///    滚动同构。
///
/// 表内矩形按声明序判定、先命中者胜；[MangaTapZoneLayout.lShaped] 的下横条与两条
/// 竖条重叠，故竖条必须排在前面。
List<MangaTapZone> mangaTapZones(
  MangaTapZoneLayout layout, {
  required bool rtl,
  bool invertHorizontal = false,
  bool invertVertical = false,
  bool invertBoth = false,
}) {
  // 只有 left_right 是「视觉方位」语义（左边那条 / 右边那条），RTL 右开本要
  // 镜像成「左 = 下一页」。其余三种是「阅读顺序」语义——Kindle 的「左窄条后退、
  // 其余整片前进」、L 型的「右侧 + 底部前进」、上下的「下半前进」——它们存在的
  // 意义就是「大片区域 = 前进」，与开本方向无关（Mihon 亦然：只有 Right and
  // Left 布局按 LEFT/RIGHT 动作走，其余布局按 NEXT/PREV 动作走、不随 RTL 翻转）。
  // 整表一律翻转会让默认 RTL 日漫下选 Kindle 布局变成「点中央 = 上一页」。
  final bool mirror = rtl && layout == MangaTapZoneLayout.leftRight;
  MangaTapZone zone(
    double left,
    double top,
    double width,
    double height,
    bool forward,
  ) => MangaTapZone(
    left: invertHorizontal || invertBoth ? 1 - left - width : left,
    top: invertVertical || invertBoth ? 1 - top - height : top,
    width: width,
    height: height,
    forward: mirror ? !forward : forward,
  );

  const double e = kMangaTapZoneEdge;
  switch (layout) {
    case MangaTapZoneLayout.disabled:
      return const <MangaTapZone>[];
    case MangaTapZoneLayout.defaultZones:
      return <MangaTapZone>[
        zone(0, 0, 1, 0.25, false),
        zone(0, 0.25, 0.25, 0.5, false),
        zone(0.75, 0.25, 0.25, 0.5, true),
        zone(0, 0.75, 1, 0.25, true),
      ];
    case MangaTapZoneLayout.edge:
      return <MangaTapZone>[
        zone(0, 0, 1, 0.1, false),
        zone(0, 0.1, 0.1, 0.8, false),
        zone(0.9, 0.1, 0.1, 0.8, true),
        zone(0, 0.9, 1, 0.1, true),
      ];
    case MangaTapZoneLayout.leftRight:
      return <MangaTapZone>[
        zone(0, 0, e, 1, false),
        zone(1 - e, 0, e, 1, true),
      ];
    case MangaTapZoneLayout.lShaped:
      return <MangaTapZone>[
        zone(0, 0, e, 1, false),
        zone(1 - e, 0, e, 1, true),
        zone(e, 1 - e, 1 - 2 * e, e, true),
      ];
    case MangaTapZoneLayout.kindle:
      return <MangaTapZone>[
        zone(0, 0, e, 1, false),
        zone(e, 0, 1 - e, 1, true),
      ];
    case MangaTapZoneLayout.topBottom:
      return <MangaTapZone>[
        zone(0, 0, 1, 0.5, false),
        zone(0, 0.5, 1, 0.5, true),
      ];
  }
}
