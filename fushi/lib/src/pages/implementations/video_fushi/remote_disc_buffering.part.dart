part of '../video_fushi_page.dart';

/// 远端原盘流式播放的「反复缓冲」提示（拍板决策：只弹一条可关闭的非强制提示，建议
/// 下载到本机，附「不再提示」，绝不强制切换）。判据在 [RemoteDiscBufferingMonitor]；
/// 提示条外观与黑闪提示条同一套（中性浮层面 + 单色图标、可点按钮），挂在同一个
/// controls Stack 里，窗口 / 全屏共用。
extension _VideoRemoteDiscBuffering on _VideoFushiPageState {
  /// controller 通知时喂一次缓冲态（只在流式原盘会话里挂）。
  void _onRemoteDiscBufferingChanged() {
    final VideoPlayerController? controller = _controller;
    if (!mounted || controller == null || widget.remoteDisc == null) return;
    if (!_videoReadyToShow) return; // 开盘前的建连缓冲不算。
    final bool suggest = _remoteDiscBufferingMonitor.update(
      buffering: controller.isBuffering,
      now: DateTime.now(),
    );
    if (!suggest) return;
    if (appModel.prefsRepo.videoDiscRemoteBufferingNoticeSuppressed) return;
    _remoteDiscBufferingNoticeNotifier.value = true;
  }

  void _dismissRemoteDiscBufferingNotice() {
    _remoteDiscBufferingNoticeNotifier.value = false;
  }

  void _suppressRemoteDiscBufferingNotice() {
    _dismissRemoteDiscBufferingNotice();
    unawaited(
      appModel.prefsRepo.setVideoDiscRemoteBufferingNoticeSuppressed(true),
    );
  }

  /// 「下载到本机」：整盘排进下载队列；当前会话照常继续播（不强制切换）。
  void _downloadRemoteDiscFromNotice() {
    _dismissRemoteDiscBufferingNotice();
    final Future<void> Function()? download =
        widget.remoteDisc?.downloadToDevice;
    if (download == null) return;
    unawaited(
      download().catchError((Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'VideoDiscMenu.remoteDownload',
          error,
          stack,
        );
        _showOsd(t.remote_video_download_failed, severity: ToastSeverity.error);
      }),
    );
  }

  Widget _buildRemoteDiscBufferingNoticeOverlay() {
    if (widget.remoteDisc == null) return const SizedBox.shrink();
    final ColorScheme cs = _videoChromeColorScheme(context);
    final bool canDownload = widget.remoteDisc?.downloadToDevice != null;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: ValueListenableBuilder<bool>(
            valueListenable: _remoteDiscBufferingNoticeNotifier,
            builder: (BuildContext _, bool visible, __) {
              return AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                child: !visible
                    ? const SizedBox.shrink()
                    : Align(
                        key: const ValueKey<String>(
                          'video-remote-disc-buffering-notice',
                        ),
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Material(
                            color: cs.surfaceContainer,
                            borderRadius: BorderRadius.circular(12),
                            clipBehavior: Clip.antiAlias,
                            elevation: kFushiFloatingElevation,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      FushiIcon(
                                        FushiIcons.download,
                                        size: 22,
                                        color: cs.primary,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          t.video_disc_remote_buffering_hint,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                color: cs.onSurface,
                                                height: 1.35,
                                              ),
                                        ),
                                      ),
                                      FushiIconButtonControl(
                                        onPressed:
                                            _dismissRemoteDiscBufferingNotice,
                                        iconSize: 20,
                                        visualDensity: VisualDensity.compact,
                                        tooltip: t.dialog_close,
                                        color: cs.onSurfaceVariant,
                                        icon: const FushiIcon(Icons.close),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: <Widget>[
                                      FushiTextButton(
                                        key: const ValueKey<String>(
                                          'video-remote-disc-buffering-dont-show',
                                        ),
                                        onPressed:
                                            _suppressRemoteDiscBufferingNotice,
                                        style: TextButton.styleFrom(
                                          foregroundColor: cs.onSurfaceVariant,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: Text(
                                          t.video_disc_remote_buffering_dont_show_again,
                                        ),
                                      ),
                                      if (canDownload) ...<Widget>[
                                        const SizedBox(width: 4),
                                        FushiFilledButton.tonal(
                                          key: const ValueKey<String>(
                                            'video-remote-disc-buffering-download',
                                          ),
                                          onPressed:
                                              _downloadRemoteDiscFromNotice,
                                          style: FilledButton.styleFrom(
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          child: Text(
                                            t.video_disc_remote_buffering_download,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
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
