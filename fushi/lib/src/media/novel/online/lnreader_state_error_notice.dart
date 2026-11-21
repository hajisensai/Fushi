import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// `state.json` 读不出来（[LnReaderManager.stateError] 非 null）时代替空列表的错误态。
///
/// 读盘失败时 [LnReaderManager.installed] / [LnReaderManager.stores] 是空占位而不是
/// 真相，所有改动都会被 [LnReaderManager.ensureReady] 拒绝；照常画「还没有小说源 /
/// 还没有仓库」的空态，用户会以为东西丢了、去重新添加，然后每一步都失败。这里如实说
/// 「没读出来」，并给一个「重试」——[LnReaderManager.initialise] 不缓存失败，再调一次
/// 就是重读。
class LnReaderStateErrorNotice extends StatefulWidget {
  const LnReaderStateErrorNotice({required this.manager, super.key});

  final LnReaderManager manager;

  @override
  State<LnReaderStateErrorNotice> createState() =>
      _LnReaderStateErrorNoticeState();
}

class _LnReaderStateErrorNoticeState extends State<LnReaderStateErrorNotice> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      // 不抛：失败照旧记在 stateError 并通知监听者，本组件随宿主重建。
      await widget.manager.initialise();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => FushiPlaceholderMessage(
    key: const ValueKey<String>('lnreader-state-load-failed'),
    icon: FushiIcons.error,
    tone: FushiPlaceholderTone.error,
    message: t.novel_sources_state_load_failed,
    action: FushiFilledButton.icon(
      onPressed: _retrying ? null : () => unawaited(_retry()),
      icon: const FushiIcon(FushiIcons.refresh),
      label: Text(t.retry),
    ),
  );
}
