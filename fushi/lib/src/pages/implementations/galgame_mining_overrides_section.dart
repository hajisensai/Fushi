import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/mining_media_quality_labels.dart'
    show miningClipFormatLabel;
import 'package:fushi/src/mining/gal_mining_settings.dart';
import 'package:fushi/src/mining/gal_mining_settings_text.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:material_ui/material_ui.dart';

/// 「跟随全局」在选项里的取值。选项用字符串（wireName）而不是可空枚举：Material
/// 下拉把 `value == null` 当成「没选中」去显示占位，选不中一个值为 null 的选项。
const String kGalMiningOverrideFollowGlobal = '';

/// 游戏详情页「本游戏制卡设置」（反馈 3dRZdakRdJ / II3jOBIhT5）。
///
/// 每一项都多一个「跟随全局」选项，并把当前全局值写在后面——用户一眼能看出不覆盖时
/// 实际会用什么。改动由宿主立即落盘（`gal_mining_overrides::<galgames.id>`），下一张
/// 卡就生效；不进编辑 Tab 的「保存」按钮：那个按钮整行 upsert 游戏条目，这里的覆盖层
/// 不在条目上。
///
/// 纯展示：值与写回都由宿主注入，本文件不碰 AppModel（不把它拖进 import 大环，见
/// `test/build/import_cycle_guard_test.dart`），也便于直接做 widget 测试。
class GalgameMiningOverridesSection extends StatelessWidget {
  const GalgameMiningOverridesSection({
    required this.overrides,
    required this.global,
    required this.onChanged,
    super.key,
  });

  /// 这个游戏当前的覆盖层（全空 = 完全跟随全局）。
  final GalGameMiningOverrides overrides;

  /// 全局 gal 制卡设置（「跟随全局」选项后面显示的值）。
  final GalMiningSettings global;

  /// 写回新的覆盖层。
  final ValueChanged<GalGameMiningOverrides> onChanged;

  void _save(GalGameMiningOverrides next) => onChanged(next);

  String _followGlobal(String globalLabel) =>
      '${t.game_mining_overrides_follow_global} · $globalLabel';

  /// 一个「跟随全局 + 各档」的选择行。[current] 为 null = 跟随全局。
  Widget _picker<T extends Enum>({
    required Key key,
    required String title,
    required IconData icon,
    required List<T> values,
    required String Function(T) wire,
    required String Function(T) label,
    required T? current,
    required T global,
    required ValueChanged<T?> onChanged,
    String? subtitle,
  }) {
    return AdaptiveSettingsPickerRow<String>(
      key: key,
      title: title,
      subtitle: subtitle,
      icon: icon,
      controlBelow: true,
      selected: current == null
          ? kGalMiningOverrideFollowGlobal
          : wire(current),
      options: <AdaptiveSettingsPickerOption<String>>[
        AdaptiveSettingsPickerOption<String>(
          value: kGalMiningOverrideFollowGlobal,
          label: _followGlobal(label(global)),
        ),
        for (final T value in values)
          AdaptiveSettingsPickerOption<String>(
            value: wire(value),
            label: label(value),
          ),
      ],
      onChanged: (String picked) {
        T? next;
        for (final T value in values) {
          if (wire(value) == picked) next = value;
        }
        onChanged(next);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final GalMiningSettings effective = GalMiningSettings.resolve(
      global: global,
      overrides: overrides,
    );
    // 历史全局值可能是 subtitleStart（与视频共用枚举）：按 isStill 归到「静态截图」档，
    // 与全局设置页同一判据。
    final VideoMiningImageMode globalImageMode = global.imageMode.isVideoClip
        ? VideoMiningImageMode.videoClip
        : global.imageMode.isStill
        ? VideoMiningImageMode.currentFrame
        : VideoMiningImageMode.gif;
    final int seconds = effective.audioLimit.seconds;
    final String secondsReadout = t.gal_mining_audio_seconds_readout(
      seconds: seconds,
    );
    final Duration motion = fushiMotionDuration(context, FushiMotion.medium);

    final List<Widget> rows = <Widget>[
      _picker<GalMiningAudioMode>(
        key: const ValueKey<String>('galgame-mining-override-audio-mode'),
        title: t.gal_mining_audio_mode,
        subtitle: t.gal_mining_audio_mode_hint,
        icon: FushiIcons.audio,
        values: GalMiningAudioMode.values,
        wire: (GalMiningAudioMode v) => v.wireName,
        label: galMiningAudioModeLabel,
        current: overrides.audioMode,
        global: global.audioLimit.mode,
        // 回到「跟随全局」时秒数一并跟随：只剩一个孤立的秒数覆盖，用户在界面上
        // 看不出它还在生效。
        onChanged: (GalMiningAudioMode? mode) => _save(
          mode == null
              ? overrides.copyWith(
                  clear: const <GalMiningOverrideField>{
                    GalMiningOverrideField.audioMode,
                    GalMiningOverrideField.audioSeconds,
                  },
                )
              : overrides.copyWith(audioMode: mode),
        ),
      ),
      // 秒数只在生效模式需要它时出现（展开 / 收起带尺寸过渡）。
      AnimatedSize(
        duration: motion,
        curve: Easing.standard,
        alignment: Alignment.topCenter,
        child: effective.audioLimit.mode.usesSeconds
            ? AdaptiveSettingsSliderRow(
                key: const ValueKey<String>(
                  'galgame-mining-override-audio-seconds',
                ),
                title: t.gal_mining_audio_seconds,
                subtitle: overrides.audioSeconds == null
                    ? _followGlobal(secondsReadout)
                    : t.gal_mining_audio_seconds_hint,
                icon: FushiIcons.timer,
                value: seconds.toDouble(),
                min: kGalMiningAudioSecondsMin.toDouble(),
                max: kGalMiningAudioSecondsMax.toDouble(),
                divisions:
                    kGalMiningAudioSecondsMax - kGalMiningAudioSecondsMin,
                step: 1,
                label: secondsReadout,
                readout: secondsReadout,
                onChanged: (double value) =>
                    _save(overrides.copyWith(audioSeconds: value.round())),
              )
            : const SizedBox(width: double.infinity),
      ),
      _picker<VideoMiningImageMode>(
        key: const ValueKey<String>('galgame-mining-override-image-mode'),
        title: t.gal_mining_image_mode,
        icon: FushiIcons.image,
        values: galMiningImageModeChoices,
        wire: (VideoMiningImageMode v) => v.wireName,
        label: galMiningImageModeLabel,
        current: overrides.imageMode,
        global: globalImageMode,
        onChanged: (VideoMiningImageMode? mode) => _save(
          mode == null
              ? overrides.copyWith(
                  clear: const <GalMiningOverrideField>{
                    GalMiningOverrideField.imageMode,
                  },
                )
              : overrides.copyWith(imageMode: mode),
        ),
      ),
      _picker<MiningClipFormat>(
        key: const ValueKey<String>('galgame-mining-override-clip-format'),
        title: t.gal_mining_clip_format,
        subtitle: t.mining_clip_format_hint,
        icon: FushiIcons.video,
        values: MiningClipFormat.values,
        wire: (MiningClipFormat v) => v.wireName,
        label: miningClipFormatLabel,
        current: overrides.clipFormat,
        global: global.clipFormat,
        onChanged: (MiningClipFormat? format) => _save(
          format == null
              ? overrides.copyWith(
                  clear: const <GalMiningOverrideField>{
                    GalMiningOverrideField.clipFormat,
                  },
                )
              : overrides.copyWith(clipFormat: format),
        ),
      ),
      _picker<MiningAnimatedFormat>(
        key: const ValueKey<String>('galgame-mining-override-animated-format'),
        title: t.gal_mining_animated_format,
        icon: FushiIcons.playCircle,
        values: MiningAnimatedFormat.values,
        wire: (MiningAnimatedFormat v) => v.wireName,
        label: galMiningAnimatedFormatLabel,
        current: overrides.animatedFormat,
        global: global.animatedFormat,
        onChanged: (MiningAnimatedFormat? format) => _save(
          format == null
              ? overrides.copyWith(
                  clear: const <GalMiningOverrideField>{
                    GalMiningOverrideField.animatedFormat,
                  },
                )
              : overrides.copyWith(animatedFormat: format),
        ),
      ),
      _picker<MiningStillFormat>(
        key: const ValueKey<String>('galgame-mining-override-still-format'),
        title: t.gal_mining_still_format,
        icon: FushiIcons.image,
        values: MiningStillFormat.values,
        wire: (MiningStillFormat v) => v.wireName,
        label: galMiningStillFormatLabel,
        current: overrides.stillFormat,
        global: global.stillFormat,
        onChanged: (MiningStillFormat? format) => _save(
          format == null
              ? overrides.copyWith(
                  clear: const <GalMiningOverrideField>{
                    GalMiningOverrideField.stillFormat,
                  },
                )
              : overrides.copyWith(stillFormat: format),
        ),
      ),
    ];

    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: FushiSectionTitle(
              t.game_mining_overrides_section,
              padding: const EdgeInsets.fromLTRB(4, 24, 4, 4),
            ),
          ),
          FushiStaggeredEntrance(
            index: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                t.game_mining_overrides_hint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          FushiStaggeredEntrance(
            index: 2,
            child: AdaptiveSettingsSection(children: rows),
          ),
          // 有覆盖时才出现「全部恢复」（淡入淡出 + 尺寸过渡）。
          AnimatedSize(
            duration: motion,
            curve: Easing.standard,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: motion,
              child: overrides.isEmpty
                  ? const SizedBox(
                      key: ValueKey<String>('no-overrides'),
                      width: double.infinity,
                    )
                  : Padding(
                      key: const ValueKey<String>(
                        'galgame-mining-override-reset',
                      ),
                      padding: const EdgeInsets.only(top: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FushiFilledButton.tonalIcon(
                          onPressed: () => _save(GalGameMiningOverrides.none),
                          icon: const FushiIcon(FushiIcons.undo),
                          label: Text(t.game_mining_overrides_reset),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
