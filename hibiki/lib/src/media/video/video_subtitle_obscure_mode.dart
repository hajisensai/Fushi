/// 视频字幕「遮蔽模式」（TODO-840 Part B）：把原本的「字幕模糊」单一 bool 开关
/// 扩成三态二选一——不遮蔽 / 模糊（听力沉浸，悬停或点击显形）/ 隐藏（主字幕整条
/// 不显示）。三态是用户对「字幕模糊功能」的优化诉求：除了模糊还想能直接隐藏。
///
/// **持久化是 preferences 层的 lazy 投影，不是新 Drift schema**（与 TODO-818 的
/// off-sentinel 第三态同范式）：底层仍写历史 bool 键 `video_subtitle_blur`
/// （[blur]/[hide] 都回写 true），并用判别键 `video_subtitle_obscure_hide`
/// （仅 [hide] 为 true）区分模糊与隐藏。这样旧版本回滚读到的就是「开着遮蔽」→
/// 退化成 blur，不会丢失用户「想遮蔽字幕」的意图（向前兼容）；新版本读时按判别键
/// 还原精确三态（向后兼容）。投影/还原的纯函数真相源是 [VideoSubtitleObscureMode]
/// 的 [fromFlags] / [blurFlag] / [hideFlag]。
enum VideoSubtitleObscureMode {
  /// 不遮蔽：字幕正常显示（历史默认，与「模糊开关关闭」像素级一致）。
  none,

  /// 模糊（听力沉浸）：字幕默认高斯模糊，桌面悬停 / 移动端点击显形，再移开 / 点击恢复。
  blur,

  /// 隐藏：主字幕整条不显示（仍可经查词 / 字幕列表 / cue 同步等其它通道访问文本）。
  hide;

  /// 历史 bool 键 `video_subtitle_blur` 的投影值：[blur] / [hide] 都为 true，[none]
  /// 为 false。旧版本只读这个键，故 hide 回退成 blur 而非「关闭」（保留遮蔽意图）。
  bool get blurFlag => this != VideoSubtitleObscureMode.none;

  /// 判别键 `video_subtitle_obscure_hide` 的投影值：仅 [hide] 为 true。
  bool get hideFlag => this == VideoSubtitleObscureMode.hide;

  /// 从两个持久化布尔标志还原三态（纯函数，preferences 读取与单测的共享真相源）。
  /// 判别键 [hideFlag] 仅在历史键 [blurFlag] 为 true 时才有意义——blur 关闭时无论
  /// hide 标志为何都视为 [none]，避免脏数据把「未遮蔽」误判成「隐藏」。
  static VideoSubtitleObscureMode fromFlags({
    required bool blurFlag,
    required bool hideFlag,
  }) {
    if (!blurFlag) return VideoSubtitleObscureMode.none;
    return hideFlag
        ? VideoSubtitleObscureMode.hide
        : VideoSubtitleObscureMode.blur;
  }

  /// 在三态之间循环（快捷键「切换遮蔽模式」用）：none -> blur -> hide -> none。
  VideoSubtitleObscureMode get next {
    switch (this) {
      case VideoSubtitleObscureMode.none:
        return VideoSubtitleObscureMode.blur;
      case VideoSubtitleObscureMode.blur:
        return VideoSubtitleObscureMode.hide;
      case VideoSubtitleObscureMode.hide:
        return VideoSubtitleObscureMode.none;
    }
  }
}
