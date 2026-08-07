// GENERATED-NOTE: TODO-1119 Windows 黑闪运行时提示条（detect + prominent banner）。
part of '../video_fushi_page.dart';

/// TODO-1119 / BUG-545：Windows「高显卡占用黑屏闪烁」运行时提示条的方法域（part-of，
/// 共享私有作用域）。字段（[_blackFlickerNoticeNotifier] / [_blackFlickerNoticeShown]）
/// 在主 shell 声明；本扩展只放：控制器回调处理 [_handleSuspectedBlackFlicker]、提示条
/// 构建 [_buildBlackFlickerNoticeOverlay] 与其上的动作（查看建议 / 不再提示 / 关闭）。
///
/// 提示条与纯展示的 OSD（[_buildOsdOverlay]，套 [IgnorePointer]）区分：它带可点按钮，
/// 故**不**套 [IgnorePointer]；非显示态渲染零尺寸不拦手势。窗口 / 全屏复用（挂在同一
/// controls Stack，与 OSD 同源，BUG-120）。判据在 [VideoBlackFlickerDetector]（控制器侧）。
extension _VideoFlickerNotice on _VideoFushiPageState {
  /// 控制器判定「疑似黑闪」时回调（仅 Windows 挂）。会话内只弹一次（[_blackFlickerNoticeShown]
  /// 门控），用户已选「不再提示」（偏好）则永不弹。满足条件则把提示条 notifier 置 true。
  void _handleSuspectedBlackFlicker() {
    if (!mounted) return;
    if (_blackFlickerNoticeShown) return;
    if (appModel.prefsRepo.videoBlackFlickerNoticeSuppressed) return;
    _blackFlickerNoticeShown = true;
    _blackFlickerNoticeNotifier.value = true;
  }

  /// 关闭提示条（仅本会话隐藏，不写偏好）。
  void _dismissBlackFlickerNotice() {
    _blackFlickerNoticeNotifier.value = false;
  }

  /// 「查看建议」：打开播放器内画质设置侧栏（画质增强 / S 形上采样 / 去色带 / 硬件解码
  /// 都在那），用户可直接降负载；同时关掉提示条。
  void _openBlackFlickerSuggestions() {
    _dismissBlackFlickerNotice();
    _showPlayerSettings();
  }

  /// 「不再提示」：落偏好（[PreferencesRepository.videoBlackFlickerNoticeSuppressed]）并关闭。
  void _suppressBlackFlickerNotice() {
    _dismissBlackFlickerNotice();
    unawaited(
      appModel.prefsRepo.setVideoBlackFlickerNoticeSuppressed(true),
    );
  }

  /// 顶部醒目提示条（MD3 errorContainer 语义色）。显示态才占尺寸并可点，隐藏态零尺寸。
  Widget _buildBlackFlickerNoticeOverlay() {
    final ColorScheme cs = _videoChromeColorScheme(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: ValueListenableBuilder<bool>(
            valueListenable: _blackFlickerNoticeNotifier,
            builder: (BuildContext _, bool visible, __) {
              if (!visible) return const SizedBox.shrink();
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Material(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    elevation: 6,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 22,
                                color: cs.onErrorContainer,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      t.video_windows_black_flash_notice_title,
                                      style: TextStyle(
                                        color: cs.onErrorContainer,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        height: 1.25,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      t.video_windows_black_flash_notice_body,
                                      style: TextStyle(
                                        color: cs.onErrorContainer,
                                        fontSize: 13,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: _dismissBlackFlickerNotice,
                                iconSize: 20,
                                visualDensity: VisualDensity.compact,
                                tooltip: t.dialog_close,
                                color: cs.onErrorContainer,
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: <Widget>[
                              TextButton(
                                onPressed: _suppressBlackFlickerNotice,
                                style: TextButton.styleFrom(
                                  foregroundColor: cs.onErrorContainer,
                                  visualDensity: VisualDensity.compact,
                                ),
                                child: Text(
                                  t.video_black_flash_notice_dont_show_again,
                                ),
                              ),
                              const SizedBox(width: 4),
                              FilledButton.tonal(
                                onPressed: _openBlackFlickerSuggestions,
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                child: Text(
                                  t.video_black_flash_notice_action,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
