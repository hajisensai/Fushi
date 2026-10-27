import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/video/discovery/video_work_acquisition_controller.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 发现作品详情页的「获取途径」：按 媒体库 / 在线源 / BT 搜索 / 媒体服务器 分组列出
/// 这部作品能从哪里拿到。每组各自的加载中 / 未配置 / 无结果 / 失败（可重试）状态
/// 全来自 [VideoWorkAcquisitionController]，本 widget 只渲染。
///
/// 组之间错峰进场（[fushiStaggeredItemBuilder]，窗口是详情页的
/// [FushiEntranceScope]）；查询是异步回来的，组内命中另开一个按状态重放的窗口，
/// 结果晚到也照样错峰进场。
class VideoWorkAcquisitionSection extends StatelessWidget {
  const VideoWorkAcquisitionSection({required this.controller, super.key});

  final VideoWorkAcquisitionController controller;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<VideoAcquisitionChannel> channels = controller.channels;
        if (channels.isEmpty) return const SizedBox.shrink();
        final NullableIndexedWidgetBuilder groupBuilder =
            fushiStaggeredItemBuilder(
              (BuildContext context, int index) => Padding(
                padding: EdgeInsets.only(
                  top: index == 0 ? 0 : tokens.spacing.section / 2,
                ),
                child: _ChannelGroup(
                  key: ValueKey<String>(
                    'video-acquisition-group-${channels[index].name}',
                  ),
                  channel: channels[index],
                  state: controller.stateOf(channels[index]),
                  onRetry: () => unawaited(controller.load(channels[index])),
                ),
              ),
            );
        return Padding(
          key: const ValueKey<String>('video-acquisition-section'),
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                MediaDetailSectionHeader(t.video_acquisition_section_title),
                for (int i = 0; i < channels.length; i++)
                  groupBuilder(context, i)!,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChannelGroup extends StatelessWidget {
  const _ChannelGroup({
    required this.channel,
    required this.state,
    required this.onRetry,
    super.key,
  });

  final VideoAcquisitionChannel channel;
  final VideoAcquisitionChannelState state;
  final VoidCallback onRetry;

  String get _keyPrefix => 'video-acquisition-${channel.name}';

  String get _title => switch (channel) {
    VideoAcquisitionChannel.library => t.video_acquisition_channel_library,
    VideoAcquisitionChannel.onlineSource =>
      t.video_acquisition_channel_online_source,
    VideoAcquisitionChannel.torrent => t.video_acquisition_channel_torrent,
    VideoAcquisitionChannel.mediaServer =>
      t.video_acquisition_channel_media_server,
  };

  IconData get _icon => switch (channel) {
    VideoAcquisitionChannel.library => FushiIcons.video,
    VideoAcquisitionChannel.onlineSource => FushiIcons.browserExtension,
    VideoAcquisitionChannel.torrent => FushiIcons.cloudDownload,
    VideoAcquisitionChannel.mediaServer => FushiIcons.server,
  };

  String get _unconfiguredMessage => switch (channel) {
    // 媒体库永远「配置好了」：本地库不需要配置。
    VideoAcquisitionChannel.library => t.video_acquisition_library_empty,
    VideoAcquisitionChannel.onlineSource =>
      t.video_acquisition_online_source_unconfigured,
    VideoAcquisitionChannel.torrent => t.video_acquisition_torrent_unconfigured,
    VideoAcquisitionChannel.mediaServer =>
      t.video_acquisition_media_server_unconfigured,
  };

  String get _configureLabel => switch (channel) {
    VideoAcquisitionChannel.library => t.retry,
    VideoAcquisitionChannel.onlineSource =>
      t.video_acquisition_online_source_configure,
    VideoAcquisitionChannel.torrent => t.video_acquisition_torrent_add_site,
    VideoAcquisitionChannel.mediaServer =>
      t.video_acquisition_media_server_configure,
  };

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
          child: Row(
            children: <Widget>[
              FushiIcon(_icon, size: 20, color: cs.primary),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
              ),
              if (state.status == VideoAcquisitionChannelStatus.loading)
                const SizedBox.square(
                  dimension: 16,
                  child: FushiCircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
            alignment: AlignmentDirectional.topStart,
            children: <Widget>[...previous, ?current],
          ),
          child: KeyedSubtree(
            key: ValueKey<String>('$_keyPrefix-switch-${state.status.name}'),
            child: _buildBody(context, tokens),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, FushiDesignTokens tokens) {
    switch (state.status) {
      case VideoAcquisitionChannelStatus.loading:
        return FushiSkeletonShimmer(
          child: Column(
            key: ValueKey<String>('$_keyPrefix-loading'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiSkeleton.line(widthFactor: 0.8, height: 14),
              const SizedBox(height: 8),
              FushiSkeleton.line(widthFactor: 0.5, height: 14),
            ],
          ),
        );
      case VideoAcquisitionChannelStatus.unconfigured:
        return _message(
          context,
          tokens,
          key: ValueKey<String>('$_keyPrefix-unconfigured'),
          text: _unconfiguredMessage,
          action: switch (state.configure) {
            final VideoAcquisitionOpen configure => FushiTextButton.icon(
              key: ValueKey<String>('$_keyPrefix-configure'),
              onPressed: () => unawaited(configure(context)),
              icon: const FushiIcon(FushiIcons.add, size: 18),
              label: Text(_configureLabel),
            ),
            null => null,
          },
        );
      case VideoAcquisitionChannelStatus.failed:
        return _message(
          context,
          tokens,
          key: ValueKey<String>('$_keyPrefix-failed'),
          text: t.video_acquisition_load_failed,
          error: true,
          action: FushiTextButton.icon(
            key: ValueKey<String>('$_keyPrefix-retry'),
            onPressed: onRetry,
            icon: const FushiIcon(FushiIcons.refresh, size: 18),
            label: Text(t.retry),
          ),
        );
      case VideoAcquisitionChannelStatus.empty:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _message(
              context,
              tokens,
              key: ValueKey<String>('$_keyPrefix-empty'),
              text: channel == VideoAcquisitionChannel.library
                  ? t.video_acquisition_library_empty
                  : t.video_acquisition_results_empty,
            ),
            ..._footer(context, tokens),
          ],
        );
      case VideoAcquisitionChannelStatus.ready:
        return _buildHits(context, tokens);
    }
  }

  Widget _buildHits(BuildContext context, FushiDesignTokens tokens) {
    final List<VideoAcquisitionHit> hits = state.hits;
    final NullableIndexedWidgetBuilder rowBuilder = fushiStaggeredItemBuilder((
      BuildContext context,
      int index,
    ) {
      final VideoAcquisitionHit hit = hits[index];
      final VideoAcquisitionOpen? open = hit.open;
      final String id = '$_keyPrefix-hit-${hit.id}';
      return FushiPressScale(
        enabled: open != null,
        child: MediaDetailItemRow(
          key: ValueKey<String>(id),
          index: index,
          count: hits.length,
          title: hit.title,
          subtitle: hit.subtitle,
          meta: hit.meta,
          titleMaxLines: 1,
          focusId: open == null ? null : FushiFocusId(id),
          trailing: open == null
              ? null
              : const FushiIcon(FushiIcons.chevronRight, size: 20),
          onTap: open == null ? null : () => unawaited(open(context)),
        ),
      );
    });
    return Column(
      key: ValueKey<String>('$_keyPrefix-ready'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (channel == VideoAcquisitionChannel.torrent)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
            child: Text(
              t.video_acquisition_torrent_found(count: state.totalCount),
              style: tokens.type.metadata,
            ),
          ),
        // 结果是异步晚到的：按状态重放一个进场窗口，命中照样错峰出现。
        FushiEntranceScope(
          replayKey: state.status,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < hits.length; i++) rowBuilder(context, i)!,
            ],
          ),
        ),
        ..._footer(context, tokens),
      ],
    );
  }

  /// 部分来源失败的提示 + 渠道入口（BT = 进完整资源搜索页）。
  List<Widget> _footer(BuildContext context, FushiDesignTokens tokens) {
    final VideoAcquisitionOpen? entry = state.entry;
    return <Widget>[
      if (state.failedSourceCount > 0)
        Padding(
          padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
          child: Text(
            t.video_acquisition_sources_partial_failed(
              count: state.failedSourceCount,
            ),
            key: ValueKey<String>('$_keyPrefix-partial-failure'),
            style: tokens.type.metadata,
          ),
        ),
      if (entry != null)
        Padding(
          padding: EdgeInsets.only(top: tokens.spacing.gap),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiPressScale(
              child: FushiFilledButton.tonalIcon(
                key: ValueKey<String>('$_keyPrefix-entry'),
                onPressed: () => unawaited(entry(context)),
                icon: const FushiIcon(FushiIcons.search),
                label: Text(t.video_discovery_resource_search),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _message(
    BuildContext context,
    FushiDesignTokens tokens, {
    required Key key,
    required String text,
    bool error = false,
    Widget? action,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Wrap(
      key: key,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        Text(
          text,
          style: tokens.type.metadata.copyWith(color: error ? cs.error : null),
        ),
        ?action,
      ],
    );
  }
}
