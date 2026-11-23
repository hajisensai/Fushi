import 'package:fushi/src/reader/page_turn_animation.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// 漫画阅读器「滑动翻页灵敏度」（拍板 R721ZgWVSB 选 b：漫画单独一个偏好，不与小说共用）。
///
/// 值域与语义照小说阅读器的 [ReaderSettings.swipePageTurnSensitivity]（BUG-2563 翻正后）：
/// **值越大越灵敏**，阈值取 `基准 / 灵敏度`；1.0 = 原先写死的手感（不改默认行为）。
const String kMangaSwipePageTurnSensitivityKey =
    'manga_swipe_page_turn_sensitivity';

const double kMangaSwipePageTurnSensitivityMin =
    ReaderSettings.minSwipePageTurnSensitivity;
const double kMangaSwipePageTurnSensitivityMax =
    ReaderSettings.maxSwipePageTurnSensitivity;
const double kMangaSwipePageTurnSensitivityDefault =
    ReaderSettings.defaultSwipePageTurnSensitivity;

/// 把落盘值（可能来自旧版本 / 同步 / 手改）夹回值域；非有限数回落默认。
double normalizeMangaSwipePageTurnSensitivity(num? value) {
  if (value == null || !value.isFinite) {
    return kMangaSwipePageTurnSensitivityDefault;
  }
  return value
      .toDouble()
      .clamp(
        kMangaSwipePageTurnSensitivityMin,
        kMangaSwipePageTurnSensitivityMax,
      )
      .toDouble();
}

/// 不跟手路径（翻页动画关 / 淡入淡出 / 跟手关）在灵敏度 1.0 时的基准：
/// 拖 ≥72px，或 ≥36px 且平均速度 ≥900px/s。
const int kMangaSwipeBaseDistPx = 72;
const int kMangaSwipeBaseFastDistPx = 36;
const int kMangaSwipeBaseFastVelocityPxPerSec = 900;

/// 跟手路径「甩动提交」要求的最小位移基准（灵敏度 1.0 时 24px）。
const int kMangaSwipeBaseFollowFlingMinPx = 24;

/// 漫画手势里「原地轻点」的判定框（`_end` 里没提交翻页时 `ax、ay` 都小于它才走单击）。
///
/// 所有**像素**翻页阈值的下界都是它：低于它，一次够不上单击框外沿的手指抖动就会被
/// 判成翻页，单击查词 / 切栏会被翻页整片吃掉（与小说 `tapSlopPx + 1` 下界同理）。
const int kMangaSwipeTapBoxPx = 20;

/// 漫画滑动翻页的全部提交阈值，Dart（卷页控制器）与手势 JS 共用这一份。
typedef MangaSwipeThresholds = ({
  /// 跟手：拖过视口宽的这一比例即提交。
  double followCommitFraction,

  /// 跟手：往翻页方向的甩速超过它（px/ms）且位移 ≥ [followFlingMinPx] 即提交。
  double followFlingVelocity,
  int followFlingMinPx,

  /// 不跟手：位移 ≥ [dist]，或位移 ≥ [fastDist] 且平均速度 ≥ [fastVelocity]（px/s）。
  int dist,
  int fastDist,
  int fastVelocity,
});

/// 按 [sensitivity] 缩放两组阈值（越灵敏阈值越小）。这是单一真相：手势 JS 的初始注入、
/// 运行中 `__mangaSetSwipeThresholds` 推送与卷页控制器都从这里取。
MangaSwipeThresholds mangaSwipeThresholds(double sensitivity) {
  final double s = normalizeMangaSwipePageTurnSensitivity(sensitivity);
  return (
    followCommitFraction: (kPageTurnFollowCommitFraction / s)
        .clamp(0.05, 0.6)
        .toDouble(),
    followFlingVelocity: (kPageTurnFollowFlingVelocity / s)
        .clamp(0.1, 4.0)
        .toDouble(),
    followFlingMinPx: (kMangaSwipeBaseFollowFlingMinPx / s).round().clamp(
      kMangaSwipeTapBoxPx,
      600,
    ),
    dist: (kMangaSwipeBaseDistPx / s).round().clamp(kMangaSwipeTapBoxPx, 600),
    fastDist: (kMangaSwipeBaseFastDistPx / s).round().clamp(
      kMangaSwipeTapBoxPx,
      600,
    ),
    fastVelocity: (kMangaSwipeBaseFastVelocityPxPerSec / s).round().clamp(
      80,
      4000,
    ),
  );
}

/// 阈值的 JS 对象字面量（`__mangaSetSwipeThresholds` 的参数，也用于初始注入）。
String mangaSwipeThresholdsJs(MangaSwipeThresholds t) =>
    '{followCommit:${t.followCommitFraction},'
    'followFling:${t.followFlingVelocity},'
    'followFlingMinPx:${t.followFlingMinPx},'
    'dist:${t.dist},'
    'fastDist:${t.fastDist},'
    'fastVel:${t.fastVelocity}}';
