/// 复习页布局的可选项（按 profile 的偏好，复习页 ⋯「复习布局」里改）。
library;

/// 底部操作行（「显示答案」/ 评分栏）一端的重播音频键。手机刷卡时拇指停在屏幕
/// 下方，够不到顶栏的重播；左右手习惯不同，所以给两端可选，默认不放（顶栏照旧有）。
enum SrsReviewReplayButton {
  off('off'),
  start('start'),
  end('end');

  const SrsReviewReplayButton(this.wire);

  /// 持久化名（偏好 `srs_review_replay_button`），冻结。
  final String wire;

  /// 未知 / 空值回落 [off]。
  static SrsReviewReplayButton fromWire(String? wire) {
    for (final SrsReviewReplayButton v in values) {
      if (v.wire == wire) return v;
    }
    return off;
  }
}

/// 复习卡面图片大小。Anki 导入卡按牌组 CSS 原样渲染，牌组常把图片限得很小
/// （`img{max-height:…}`），原图像素小时也只按原尺寸画；这里给一个覆盖档。
enum SrsReviewImageSize {
  /// 按卡片模板 / 牌组 CSS 原样。
  original('original'),

  /// 去掉牌组的尺寸上限，宽于卡面时等比缩到卡面宽（不放大小图）。
  fitWidth('fit_width'),

  /// 小图也等比放大到卡面宽，高度最多占视口的 [kSrsReviewLargeImageMaxVh]%
  /// （更高就整张等比缩小，不裁切）。
  large('large');

  const SrsReviewImageSize(this.wire);

  /// 持久化名（偏好 `srs_review_image_size`），冻结。
  final String wire;

  /// 未知 / 空值回落 [original]。
  static SrsReviewImageSize fromWire(String? wire) {
    for (final SrsReviewImageSize v in values) {
      if (v.wire == wire) return v;
    }
    return original;
  }
}

/// [SrsReviewImageSize.large] 下卡面图片最高占视口高度的百分比。
const int kSrsReviewLargeImageMaxVh = 75;

/// [size] 对应的卡面图片样式，经卡面 `hostCss` 随主题原地下发（不重放卡片）。
///
/// 规则要压过牌组 CSS 里的 `img{max-height:…}` / 内联 `width` 属性，所以带
/// `!important`；`.card` 前缀只作用于卡面正文，不碰外壳里的播放按钮等。
String srsReviewImageSizeCss(SrsReviewImageSize size) => switch (size) {
  SrsReviewImageSize.original => '',
  SrsReviewImageSize.fitWidth =>
    '.card img{max-width:100%!important;max-height:none!important;'
        'height:auto!important;}',
  SrsReviewImageSize.large =>
    '.card img{width:100%!important;max-width:100%!important;'
        'height:auto!important;'
        'max-height:${kSrsReviewLargeImageMaxVh}vh!important;'
        'object-fit:contain;}',
};
