import 'package:flutter/material.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// 编辑「单个本地音频库」的子来源：拖拽调整优先级顺序 + 逐源启用/禁用。
///
/// 进入时把 [savedPrefs]（已存的偏好）与 [listSources]（库内实际枚举到的 source）
/// 合并：存里有的保序、库里新出现的追加（默认启用）、库里已消失的丢弃。关闭时
/// 通过 [onApply] 即时持久化（不走主对话框的批量保存）。
class LocalAudioSourcesDialog extends StatefulWidget {
  const LocalAudioSourcesDialog({
    required this.dbPath,
    required this.savedPrefs,
    required this.listSources,
    required this.onApply,
    super.key,
  });

  final String dbPath;
  final List<LocalAudioSourcePref> savedPrefs;
  final Future<List<String>> Function() listSources;
  final Future<void> Function(List<LocalAudioSourcePref>) onApply;

  /// 合并已存偏好与库内实际来源：保序 + 追加新源（默认启用）+ 丢弃消失源。
  @visibleForTesting
  static List<LocalAudioSourcePref> merge(
    List<LocalAudioSourcePref> saved,
    List<String> discovered,
  ) {
    final Set<String> known =
        saved.map((LocalAudioSourcePref s) => s.name).toSet();
    return <LocalAudioSourcePref>[
      for (final LocalAudioSourcePref s in saved)
        if (discovered.contains(s.name)) s, // 保序、丢弃已消失的
      for (final String name in discovered)
        if (!known.contains(name)) LocalAudioSourcePref(name: name), // 追加新源
    ];
  }

  @override
  State<LocalAudioSourcesDialog> createState() =>
      _LocalAudioSourcesDialogState();
}

class _LocalAudioSourcesDialogState extends State<LocalAudioSourcesDialog> {
  List<LocalAudioSourcePref>? _prefs; // null = 仍在枚举

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<String> discovered = await widget.listSources();
    if (!mounted) return;
    setState(() =>
        _prefs = LocalAudioSourcesDialog.merge(widget.savedPrefs, discovered));
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double maxHeight =
        (MediaQuery.of(context).size.height * 0.55).clamp(128.0, 420.0);

    return HibikiDialogFrame(
      maxWidth: 480,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.local_audio_source_order_title,
        leadingIcon: Icons.tune,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: double.maxFinite,
            maxHeight: maxHeight,
          ),
          child: _buildBody(tokens),
        ),
        footer: Align(
          alignment: Alignment.centerRight,
          child: adaptiveDialogAction(
            context: context,
            onPressed: () {
              final List<LocalAudioSourcePref>? prefs = _prefs;
              if (prefs != null) widget.onApply(prefs);
              Navigator.pop(context);
            },
            child: Text(t.dialog_close),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(HibikiDesignTokens tokens) {
    final List<LocalAudioSourcePref>? prefs = _prefs;
    if (prefs == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (prefs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.local_audio_no_sources,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      itemCount: prefs.length,
      onReorder: (int oldIndex, int newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final LocalAudioSourcePref item = prefs.removeAt(oldIndex);
          prefs.insert(newIndex, item);
        });
      },
      itemBuilder: (BuildContext context, int index) {
        final LocalAudioSourcePref source = prefs[index];
        return AdaptiveSettingsRow(
          key: ValueKey<String>('local_audio_source_${source.name}'),
          title: source.name,
          icon: Icons.drag_handle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Switch.adaptive(
                value: source.enabled,
                onChanged: (bool enabled) => setState(() {
                  prefs[index] = source.copyWith(enabled: enabled);
                }),
              ),
              HibikiIconButton(
                icon: Icons.keyboard_arrow_up,
                size: 18,
                tooltip: t.move_up,
                enabled: index > 0,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => setState(() {
                  final LocalAudioSourcePref item = prefs.removeAt(index);
                  prefs.insert(index - 1, item);
                }),
              ),
              HibikiIconButton(
                icon: Icons.keyboard_arrow_down,
                size: 18,
                tooltip: t.move_down,
                enabled: index < prefs.length - 1,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => setState(() {
                  final LocalAudioSourcePref item = prefs.removeAt(index);
                  prefs.insert(index + 1, item);
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}
