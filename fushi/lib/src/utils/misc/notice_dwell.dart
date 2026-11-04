/// 应用内短时提示的**停留时长**（单一真相源）：按提示的类别取，调用点不另写毫秒数。
///
/// 停留时长 = 提示完整可见的时间，不含进退场动画（动画时长走 `FushiMotion`）。
///
/// 类别：
/// - `flash`：回显用户**刚做完**的动作（复习评分「已评：重来 · 15分钟后到期」这类）。
///   用户已经知道自己点了什么，提示只是确认一眼，闪一下就收（反馈 vKGS1y9-v2）。
/// - `short` / `long`：底部 `FushiToast.show` 的 `Toast.LENGTH_SHORT` / `LENGTH_LONG`。
/// - `mineResult` / `minePending`：制卡结果卡；pending 停更久，等结果卡顶替它。
library;

abstract final class FushiNoticeDwell {
  /// 动作结果回显：闪一下。
  static const Duration flash = Duration(milliseconds: 1200);

  /// 普通短提示（`Toast.LENGTH_SHORT`）。
  static const Duration short = Duration(milliseconds: 2000);

  /// 普通长提示（`Toast.LENGTH_LONG`）。
  static const Duration long = Duration(milliseconds: 3500);

  /// 制卡结果（成功 / 重复 / 失败 / 待发）。
  static const Duration mineResult = Duration(milliseconds: 2400);

  /// 制卡中（等结果卡顶替）。
  static const Duration minePending = Duration(milliseconds: 4000);
}
