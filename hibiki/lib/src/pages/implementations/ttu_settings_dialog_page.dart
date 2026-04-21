import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:wakelock/wakelock.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used for managing Reader settings.
class TtuSettingsDialogPage extends BasePage {
  /// Create an instance of this page.
  const TtuSettingsDialogPage({super.key});

  @override
  BasePageState createState() => _DictionaryDialogPageState();
}

class _DictionaryDialogPageState extends BasePageState {
  ReaderTtuSource get source => ReaderTtuSource.instance;

  late TextEditingController _speedController;

  @override
  void initState() {
    super.initState();

    _speedController =
        TextEditingController(text: source.volumePageTurningSpeed.toString());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: MediaQuery.of(context).orientation == Orientation.portrait
          ? Spacing.of(context).insets.exceptBottom.big
          : Spacing.of(context).insets.exceptBottom.normal.copyWith(
                left: Spacing.of(context).spaces.semiBig,
                right: Spacing.of(context).spaces.semiBig,
              ),
      actionsPadding: Spacing.of(context).insets.exceptBottom.normal.copyWith(
            left: Spacing.of(context).spaces.normal,
            right: Spacing.of(context).spaces.normal,
            bottom: Spacing.of(context).spaces.normal,
            top: Spacing.of(context).spaces.extraSmall,
          ),
      content: buildContent(),
      actions: actions,
    );
  }

  List<Widget> get actions => [
        buildCloseButton(),
      ];

  Widget buildCloseButton() {
    return TextButton(
      child: Text(t.dialog_close),
      onPressed: () => Navigator.pop(context),
    );
  }

  Widget buildContent() {
    ScrollController contentController = ScrollController();

    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: contentController,
        child: SingleChildScrollView(
          controller: contentController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildReaderSettingsSection(),
              const Space.small(),
              const JidoujishoDivider(),
              const Space.small(),
              buildHighlightOnTapSwitch(),
              buildEnablePageTurningSwitch(),
              buildInvertPageTurningSwitch(),
              buildExtendPageSwitch(),
              buildAdaptThemeSwitch(),
              buildKeepScreenAwakeSwitch(),
              const Space.small(),
              const JidoujishoDivider(),
              buildPageTurningSpeedField(),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildEnablePageTurningSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(source.volumePageTurningEnabled);

    return Row(
      children: [
        Expanded(
          child: Text(t.volume_button_page_turning),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                source.toggleVolumePageTurningEnabled();
                notifier.value = source.volumePageTurningEnabled;
                VolumeKeyChannel.instance
                    .setInterceptEnabled(source.volumePageTurningEnabled);
              },
            );
          },
        )
      ],
    );
  }

  Widget buildInvertPageTurningSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(source.volumePageTurningInverted);

    return Row(
      children: [
        Expanded(
          child: Text(t.invert_volume_buttons),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                source.toggleVolumePageTurningInverted();
                notifier.value = source.volumePageTurningInverted;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildExtendPageSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(source.extendPageBeyondNavigationBar);

    return Row(
      children: [
        Expanded(
          child: Text(t.extend_page_beyond_navbar),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                source.toggleExtendPageBeyondNavigationBar();
                notifier.value = source.extendPageBeyondNavigationBar;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildAdaptThemeSwitch() {
    ValueNotifier<bool> notifier = ValueNotifier<bool>(source.adaptTtuTheme);

    return Row(
      children: [
        Expanded(
          child: Text(t.adapt_ttu_theme),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                source.toggleAdaptTtuTheme();
                notifier.value = source.adaptTtuTheme;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildKeepScreenAwakeSwitch() {
    ValueNotifier<bool> notifier =
        ValueNotifier<bool>(source.keepScreenAwake);

    return Row(
      children: [
        Expanded(
          child: Text(t.keep_screen_awake),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) async {
                source.toggleKeepScreenAwake();
                notifier.value = source.keepScreenAwake;
                if (source.keepScreenAwake) {
                  await Wakelock.enable();
                } else {
                  await Wakelock.disable();
                }
              },
            );
          },
        )
      ],
    );
  }

  Widget buildHighlightOnTapSwitch() {
    ValueNotifier<bool> notifier = ValueNotifier<bool>(source.highlightOnTap);

    return Row(
      children: [
        Expanded(
          child: Text(t.highlight_on_tap),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: notifier,
          builder: (_, value, __) {
            return Switch(
              value: value,
              onChanged: (value) {
                source.toggleHighlightOnTap();
                notifier.value = source.highlightOnTap;
              },
            );
          },
        )
      ],
    );
  }

  Widget buildReaderSettingsSection() {
    return StatefulBuilder(
      builder: (BuildContext ctx, StateSetter setLocal) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 字体大小
            _numberRow(
              label: '字体大小',
              value: source.ttuFontSize,
              step: 1,
              min: 8,
              max: 64,
              format: (v) => '${v.round()}',
              onChanged: (v) {
                source.setTtuFontSize(v);
                setLocal(() {});
              },
            ),
            // 行高
            _numberRow(
              label: '行高',
              value: source.ttuLineHeight,
              step: 0.1,
              min: 1.0,
              max: 3.0,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) {
                source.setTtuLineHeight(
                    (v * 100).roundToDouble() / 100);
                setLocal(() {});
              },
            ),
            // 排版方向
            Row(
              children: [
                const Expanded(child: Text('排版方向')),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'horizontal-tb', label: Text('横排')),
                    ButtonSegment(value: 'vertical-rl', label: Text('竖排')),
                  ],
                  selected: {source.ttuWritingMode},
                  onSelectionChanged: (sel) {
                    source.setTtuWritingMode(sel.first);
                    setLocal(() {});
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 视图模式
            Row(
              children: [
                const Expanded(child: Text('视图模式')),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'paginated', label: Text('翻页')),
                    ButtonSegment(value: 'continuous', label: Text('滚动')),
                  ],
                  selected: {source.ttuViewMode},
                  onSelectionChanged: (sel) {
                    source.setTtuViewMode(sel.first);
                    setLocal(() {});
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 主题
            const Text('主题'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: TtuReaderSettings.availableThemes.map((t) {
                return ChoiceChip(
                  label: Text(TtuReaderSettings.themeLabels[t] ?? t),
                  selected: source.ttuTheme == t,
                  onSelected: (on) {
                    if (!on) return;
                    source.setTtuTheme(t);
                    setLocal(() {});
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 4),
            // 隐藏假名
            Row(
              children: [
                const Expanded(child: Text('隐藏振假名')),
                Switch(
                  value: source.ttuHideFurigana,
                  onChanged: (v) {
                    source.setTtuHideFurigana(v);
                    setLocal(() {});
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _numberRow({
    required String label,
    required double value,
    required double step,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged((value - step).clamp(min, max)),
          ),
          SizedBox(
            width: 42,
            child: Text(format(value), textAlign: TextAlign.center),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged((value + step).clamp(min, max)),
          ),
        ],
      ),
    );
  }

  Widget buildPageTurningSpeedField() {
    return TextField(
      onChanged: (value) {
        double newSpeed = double.tryParse(value) ??
            ReaderTtuSource.defaultScrollingSpeed.toDouble();
        if (newSpeed.isNegative) {
          newSpeed = ReaderTtuSource.defaultScrollingSpeed.toDouble();
          _speedController.text = newSpeed.toString();
        }

        source.setVolumePageTurningSpeed(newSpeed.toInt());
      },
      controller: _speedController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        floatingLabelBehavior: FloatingLabelBehavior.always,
        suffixIcon: JidoujishoIconButton(
          tooltip: t.reset,
          size: 18,
          onTap: () async {
            _speedController.text =
                ReaderTtuSource.defaultScrollingSpeed.toString();
            source.setVolumePageTurningSpeed(
                ReaderTtuSource.defaultScrollingSpeed);
            FocusScope.of(context).unfocus();
          },
          icon: Icons.undo,
        ),
        labelText: t.volume_button_turning_speed,
      ),
    );
  }
}
