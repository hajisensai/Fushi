/// 「未配音」列表：合成失败、成品里暂时是占位静音的句子。每句可以换配置重试 /
/// 指定声音 / 手动填写，也可以一次全部换配置重试；页头能改重试候选声音。
///
/// 页面只管展示与收集用户的选择，真正的补回（合成、写选角表、记账、重做受影响的章）
/// 由 [TtsUnvoicedPage.backfill] 交给 `tts_unvoiced_backfill.dart`。
library;

import 'dart:async';

import 'package:fushi_engine/tts/tts_types.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_unvoiced_backfill.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 列表里的一句。
typedef TtsUnvoicedLineView = ({
  String lineId,

  /// 原文（有手动填写的念法时是念法）。
  String text,

  /// 最近一次失败码（账本里的 `code`）。
  String? code,

  /// 失败次数。
  int attempts,
});

/// 账本失败码 → 文案：引擎失败码（`TtsFailureCode.name`）走 TTS 的失败文案，
/// 其余（`voice_missing` 等）走制作的失败文案。
String ttsUnvoicedCodeText(String? code) {
  for (final TtsFailureCode value in TtsFailureCode.values) {
    if (value.name == code) return ttsFailureText(TtsFailure(value));
  }
  return ttsRenderFailureText(code);
}

/// 补回结果的提示文案。
String ttsBackfillResultText(TtsBackfillResult r) => <String>[
  if (r.succeeded > 0 || r.failed > 0)
    t.audiobook_studio_unvoiced_result(ok: r.succeeded, failed: r.failed),
  if (r.exhausted > 0) t.audiobook_studio_unvoiced_exhausted(n: r.exhausted),
  if (r.renderQueued) t.audiobook_studio_unvoiced_rerender,
  if (r.renderBusy) t.audiobook_studio_unvoiced_render_busy,
].join('\n');

class TtsUnvoicedPage extends StatefulWidget {
  const TtsUnvoicedPage({
    required this.load,
    required this.backfill,
    required this.voiceOptions,
    required this.onAddVoice,
    required this.retryVoicesSummary,
    required this.onEditRetryVoices,
    super.key,
  });

  /// 读当前账本（补回后重新读）。
  final Future<List<TtsUnvoicedLineView>> Function() load;

  /// 执行补回；[onProgress] = 已试句数 / 待试句数。
  final Future<TtsBackfillResult> Function(
    List<TtsBackfillRequest> requests,
    void Function(int done, int total) onProgress,
  )
  backfill;

  /// 「指定声音」的候选（value = 预设 id）。
  final List<FushiChoiceOption<String>> Function() voiceOptions;

  /// 「指定声音」弹窗末尾的「添加声音」：返回新声音 id，取消返回 null。
  final Future<String?> Function() onAddVoice;

  /// 页头「重试候选声音」那一行的摘要。
  final String Function() retryVoicesSummary;
  final Future<void> Function() onEditRetryVoices;

  @override
  State<TtsUnvoicedPage> createState() => _TtsUnvoicedPageState();
}

class _TtsUnvoicedPageState extends State<TtsUnvoicedPage> {
  List<TtsUnvoicedLineView>? _lines;
  bool _busy = false;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final List<TtsUnvoicedLineView> lines = await widget.load();
    if (mounted) setState(() => _lines = lines);
  }

  Future<void> _run(List<TtsBackfillRequest> requests) async {
    if (_busy || requests.isEmpty) return;
    setState(() {
      _busy = true;
      _done = 0;
      _total = requests.length;
    });
    try {
      final TtsBackfillResult result = await widget.backfill(requests, (
        int done,
        int total,
      ) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
        });
      });
      final String message = ttsBackfillResultText(result);
      if (message.isNotEmpty) FushiToast.show(msg: message);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _pickVoice(TtsUnvoicedLineView line) async {
    final String? picked = await showTtsVoicePickDialog(
      context: context,
      title: t.audiobook_studio_unvoiced_pick_voice,
      message: line.text,
      options: widget.voiceOptions(),
      // 加完声音后 [TtsUnvoicedPage.voiceOptions] 已含新声音，下次打开就有。
      onAdd: widget.onAddVoice,
    );
    if (picked == null || !mounted) return;
    await _run(<TtsBackfillRequest>[
      TtsBackfillRequest.voice(line.lineId, picked),
    ]);
  }

  Future<void> _typeText(TtsUnvoicedLineView line) async {
    final String? typed = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_studio_unvoiced_type_text,
      initialValue: line.text,
      icon: FushiIcons.textFields,
      maxLines: 4,
    );
    if (typed == null || typed.trim().isEmpty || !mounted) return;
    await _run(<TtsBackfillRequest>[
      TtsBackfillRequest.say(line.lineId, typed),
    ]);
  }

  Future<void> _editRetryVoices() async {
    await widget.onEditRetryVoices();
    if (mounted) setState(() {});
  }

  Widget _header(List<TtsUnvoicedLineView> lines) {
    final double inset = FushiDesignTokens.of(context).spacing.rowHorizontal;
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('tts-unvoiced-header'),
      title: t.audiobook_studio_unvoiced_count(n: lines.length),
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('tts-unvoiced-retry-voices'),
          icon: FushiIcons.voice,
          showIcon: true,
          title: t.audiobook_studio_retry_voices,
          subtitle: widget.retryVoicesSummary(),
          onTap: _busy ? null : () => unawaited(_editRetryVoices()),
        ),
        if (lines.isNotEmpty)
          AdaptiveSettingsRow(
            key: const ValueKey<String>('tts-unvoiced-retry-all'),
            icon: FushiIcons.refresh,
            showIcon: true,
            title: t.audiobook_studio_unvoiced_retry_all,
            onTap: _busy
                ? null
                : () => unawaited(
                    _run(<TtsBackfillRequest>[
                      for (final TtsUnvoicedLineView l in lines)
                        TtsBackfillRequest.retryNext(l.lineId),
                    ]),
                  ),
          ),
        if (_busy)
          Padding(
            key: const ValueKey<String>('tts-unvoiced-progress'),
            padding: EdgeInsets.fromLTRB(inset, 8, inset, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.audiobook_studio_unvoiced_working(
                    done: _done,
                    total: _total,
                  ),
                ),
                const SizedBox(height: 8),
                FushiLinearProgressIndicator(
                  value: _total <= 0 ? null : (_done / _total).clamp(0.0, 1.0),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(TtsUnvoicedLineView line) {
    final String id = line.lineId;
    return FushiListItem(
      key: ValueKey<String>('tts-unvoiced-line-$id'),
      leading: const FushiIcon(FushiIcons.warning),
      title: Text(line.text, maxLines: 4, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        t.audiobook_studio_unvoiced_attempts(
          n: line.attempts,
          reason: ttsUnvoicedCodeText(line.code),
        ),
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIconButtonControl(
            key: ValueKey<String>('tts-unvoiced-line-$id-retry'),
            tooltip: t.audiobook_studio_unvoiced_retry_next,
            icon: const FushiIcon(FushiIcons.refresh),
            onPressed: _busy
                ? null
                : () => unawaited(
                    _run(<TtsBackfillRequest>[
                      TtsBackfillRequest.retryNext(id),
                    ]),
                  ),
          ),
          FushiIconButtonControl(
            key: ValueKey<String>('tts-unvoiced-line-$id-voice'),
            tooltip: t.audiobook_studio_unvoiced_pick_voice,
            icon: const FushiIcon(FushiIcons.voice),
            onPressed: _busy ? null : () => unawaited(_pickVoice(line)),
          ),
          FushiIconButtonControl(
            key: ValueKey<String>('tts-unvoiced-line-$id-say'),
            tooltip: t.audiobook_studio_unvoiced_type_text,
            icon: const FushiIcon(FushiIcons.edit),
            onPressed: _busy ? null : () => unawaited(_typeText(line)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final List<TtsUnvoicedLineView>? lines = _lines;
    return SettingsKitScaffold(
      title: t.audiobook_studio_unvoiced_title,
      leadingIcon: FushiIcons.warning,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            if (lines == null) {
              return const Center(child: FushiCircularProgressIndicator());
            }
            final int extra = lines.isEmpty ? 2 : 1;
            return FushiEntranceScope(
              child: ListView.builder(
                key: const ValueKey<String>('tts-unvoiced-list'),
                controller: controller,
                padding: EdgeInsets.fromLTRB(
                  inset,
                  tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                  inset,
                  tokens.spacing.page + bottomSafeInsetOf(context),
                ),
                itemCount: lines.length + extra,
                itemBuilder: fushiStaggeredItemBuilder((
                  BuildContext context,
                  int index,
                ) {
                  if (index == 0) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _header(lines),
                        Padding(
                          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                          child: Text(
                            t.audiobook_studio_unvoiced_hint,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    );
                  }
                  if (lines.isEmpty) {
                    return Padding(
                      key: const ValueKey<String>('tts-unvoiced-empty'),
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        t.audiobook_studio_unvoiced_empty,
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  return _row(lines[index - 1]);
                }),
              ),
            );
          },
    );
  }
}
