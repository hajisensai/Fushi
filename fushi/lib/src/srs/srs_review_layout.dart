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
