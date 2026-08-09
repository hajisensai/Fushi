import 'package:flutter/material.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/utils.dart';

/// 会话音轨面板（共享内容组件）：轨列表 + 逐轨试听 + 设为语音轨 + 排除 BGM/恢复。
///
/// 同一份 UI 挂两处——诊断页的音轨卡片、捕获工作台顶栏的音轨对话框。此前排除 BGM
/// 只能从「某一句的选轨对话框」进（先随便找一句点改轨才能排除，入口藏反了）；抽成
/// 共享组件后工作台一键直达，两处不再各写一份轨列表。
///
/// 交互契约（沿诊断页既有语义，BUG-1027/1102）：
/// - 试听不经过选轨/排除字段（显式传 sourcePtr），任何后端都可用；
/// - 「设为语音轨」「排除」只在引擎 PCM 后端可用（[galTrackSelectionAffectsCapture]），
///   其余后端禁用并给解释态，不渲染点了没反应的死控件；
/// - 近窗零片段的轨照样列出但置灰标注（用户需要知道它存在）。
class GalAudioTracksPanel extends StatelessWidget {
  const GalAudioTracksPanel({
    super.key,
    required this.state,
    required this.onSelectVoice,
    required this.onToggleExcluded,
    required this.onPreviewTrack,
    required this.previewingSourcePtr,
  });

  final GalHookSessionState state;
  final ValueChanged<int> onSelectVoice;
  final void Function(int sourcePtr, bool excluded) onToggleExcluded;
  final ValueChanged<GalAudioTrack> onPreviewTrack;
  final int? previewingSourcePtr;

  @override
  Widget build(BuildContext context) {
    // BUG-1027：gameResource / 纯 Loopback 模式下 PCM 音轨列表**本就不存在**，
    // 通用「尚无音轨数据」会误导用户以为音频链路故障——改为按后端给解释态，
    // 且不再渲染只对引擎 PCM 有意义的「自动选择」radio。
    //
    // BUG-1102：解释态与禁用判据都必须看**后端**，不是看列表空不空。
    final GalTrackEmptyHint emptyHint =
        galTrackEmptyHintFor(state.audioBackend);
    final bool selectionEffective =
        galTrackSelectionAffectsCapture(state.audioBackend);
    final String? backendHint = selectionEffective
        ? null
        : switch (emptyHint) {
            GalTrackEmptyHint.resourceMode => t.game_tracks_resource_mode_hint,
            GalTrackEmptyHint.loopbackMode => t.game_tracks_loopback_hint,
            GalTrackEmptyHint.generic =>
              state.audioTracks.isEmpty ? null : t.game_tracks_pcm_only_hint,
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (backendHint != null)
          _PanelHintBox(icon: Icons.info_outline, text: backendHint),
        // 「自动选择」只对引擎 PCM 有意义；其余后端不渲染它，免得暗示能选。
        if (selectionEffective)
          RadioListTile<int>(
            contentPadding: EdgeInsets.zero,
            value: 0,
            groupValue: state.selectedAudioSourcePtr,
            onChanged: (int? value) => onSelectVoice(value ?? 0),
            title: Text(t.game_track_auto),
            secondary: const Icon(Icons.auto_awesome_outlined),
          ),
        if (state.audioTracks.isEmpty && backendHint == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(t.game_no_tracks),
          )
        else
          // 抓不到片段的轨照样列出来（用户需要知道它存在），但明确标注并置灰，
          // 不再让它看起来和可用轨一样（BUG-1102 ②）。
          for (final GalAudioTrack track in state.audioTracks)
            GalTrackTile(
              track: track,
              selected: state.selectedAudioSourcePtr == track.sourcePtr,
              excluded: state.excludedAudioSourcePtrs.contains(track.sourcePtr),
              previewing: previewingSourcePtr == track.sourcePtr,
              selectable: selectionEffective,
              onSelect: () => onSelectVoice(track.sourcePtr),
              onPreview: () => onPreviewTrack(track),
              onToggleExcluded: (bool excluded) =>
                  onToggleExcluded(track.sourcePtr, excluded),
            ),
      ],
    );
  }
}

/// 单条音轨行：格式/片段数/能量元数据 + 试听 / 设为语音轨 / 排除 BGM 三操作。
class GalTrackTile extends StatelessWidget {
  const GalTrackTile({
    super.key,
    required this.track,
    required this.selected,
    required this.excluded,
    required this.previewing,
    required this.selectable,
    required this.onSelect,
    required this.onPreview,
    required this.onToggleExcluded,
    this.selectTooltip,
  });

  final GalAudioTrack track;
  final bool selected;
  final bool excluded;

  /// 该轨是否正在试听（按钮显示为停止）。
  final bool previewing;

  /// 当前音频后端是否真的消费选轨/排除（BUG-1102）。false 时这两个控件禁用——
  /// 让用户点一个不会生效的按钮比直接说清楚更糟。试听仍可用（它显式传 sourcePtr、
  /// 不经过这两个字段），用户仍能靠它判断哪条是语音。
  final bool selectable;
  final VoidCallback onSelect;
  final VoidCallback onPreview;
  final ValueChanged<bool> onToggleExcluded;

  /// 「设为语音轨」按钮的文案。会话面板是「选为会话语音轨」，逐句面板是「用于本句」
  /// ——同一个控件两种作用域，文案必须说清改的是哪个，否则用户以为点了会话级。
  final String? selectTooltip;

  @override
  Widget build(BuildContext context) {
    final PcmFormat format = track.format;
    // 当前这句时刻窗内一个片段都没有的轨：留在列表里（用户需要知道它存在），但明确
    // 标注并置灰，不再让它看起来和真能取到语音的轨一样（BUG-1102 ②）。
    //
    // BUG-1165：原判据是 `clipCount <= 0`，而 native 的 clip_count 是**全环累计**
    // （voice_hook_reader.cpp 的 clip_count++ 无时间窗过滤），一条轨能被列出就至少
    // 有 1 个片段——条件恒假，置灰从来没生效过。游戏音频引擎常年维护一池 source
    // voice（SE、系统音、播完的旧语音都在环里），于是列表里永远挂着一堆点了没声音
    // 的轨。真正表达「此刻有没有响」的是时刻窗内片段数，见 [GalAudioTrack.isSilentAtCue]。
    final bool silent = track.isSilentAtCue;
    return IgnorePointer(
      ignoring: silent,
      child: Opacity(
        opacity: silent ? 0.56 : 1,
        child: FushiListItem(
          padding: EdgeInsets.zero,
          selected: selected,
          leading: Icon(
            excluded ? Icons.music_off_outlined : Icons.graphic_eq,
          ),
          title: Text(
            '${t.game_track_voice} ${track.orderIndex + 1} · ${format.sampleRate} Hz · ${format.channels} ch',
          ),
          subtitle: Text(
            <String>[
              '0x${track.sourcePtr.toRadixString(16)}',
              '${t.game_track_clips} ${track.clipCount}',
              // 能量只在真算得出来时显示。旧实现无条件打印，非 16-bit 轨和此刻
              // 没响的轨都显示「能量 -1.0」——那是内部哨兵值，不是给用户看的。
              if (track.avgEnergy >= 0)
                '${t.game_track_energy} ${track.avgEnergy.toStringAsFixed(1)}',
              if (excluded) t.game_track_bgm,
              if (silent) t.game_track_silent_at_cue,
            ].join(' · '),
          ),
          trailing: Wrap(
            spacing: 4,
            children: <Widget>[
              // BUG-1027：逐轨试听——抓该轨最近整句 PCM 播放，帮用户判断这条轨
              // 是语音还是 BGM，再决定选轨/排除。播放中变停止按钮。
              FushiIconButton(
                icon: previewing
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
                tooltip: previewing
                    ? t.game_track_preview_stop
                    : t.game_track_preview,
                onTap: onPreview,
              ),
              FushiIconButton(
                icon: selected ? Icons.check_circle : Icons.circle_outlined,
                tooltip: selectTooltip ?? t.game_track_select_as_voice,
                enabled: selectable && !excluded,
                onTap: onSelect,
              ),
              FushiIconButton(
                icon: excluded ? Icons.undo : Icons.music_off_outlined,
                tooltip:
                    excluded ? t.game_track_restore : t.game_track_exclude_bgm,
                enabled: selectable,
                onTap: () => onToggleExcluded(!excluded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板内解释态信息条（样式对齐诊断页 `_DetailBox` 的非错误形态）。
class _PanelHintBox extends StatelessWidget {
  const _PanelHintBox({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Container(
      margin: EdgeInsets.only(top: tokens.spacing.gap),
      padding: EdgeInsets.all(tokens.spacing.gap + 2),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: colors.onSecondaryContainer, size: 18),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: colors.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
