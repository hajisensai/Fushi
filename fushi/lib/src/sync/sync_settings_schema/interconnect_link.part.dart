part of '../sync_settings_schema.dart';

// ── 扫码 / 深链 / NFC 配对 UI（docs/specs/2026-09-28-interconnect-remote-reach.md §4）
//
// 设置页与根级深链处理（main.dart 的 `fushi://pair`）共用本文件的入口。编排本身
// 在 `interconnect_link_pairing.dart`，这里只管弹窗、扫码页与 NFC 通道。

/// 本机能否用相机扫配对二维码。桌面通常是出示二维码的一方，Mac 用「粘贴配对链接」。
bool get interconnectPairQrScanSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// 本机能否把配对链接写进 NFC 贴纸（Android 原生通道；iOS 只能读不能写贴纸
/// 以外的场景且需额外 entitlement，不做）。
bool get interconnectPairNfcWriteSupported => !kIsWeb && Platform.isAndroid;

/// 与 `ChannelNames.NFC_TAG_WRITER`（`NfcTagWriterChannelHandler.java`）同名，
/// 方法名 / 参数名是跨语言契约。
const MethodChannel _interconnectNfcChannel = MethodChannel(
  'app.fushi.reader/nfc_tag_writer',
);

/// 按链接配对的完整交互：确认身份（链接可能来自任何网页，**必须**用户确认）→
/// 配对 → 提示结果。返回是否配对成功。
Future<bool> runInterconnectLinkPairingFlow(
  BuildContext context,
  AppModel appModel,
  FushiPairLink link,
) async {
  final String address = link.addresses
      .where(
        (InterconnectHostAddress a) => a.kind != InterconnectAddressKind.p2p,
      )
      .map((InterconnectHostAddress a) => a.url)
      .join('\n');
  final bool confirmed = await confirmInterconnectPairIdentity(
    context,
    deviceName: link.deviceName,
    fingerprint: link.fingerprint,
    address: address,
  );
  if (!confirmed || !context.mounted) return false;
  final SyncRepository repo = SyncRepository(appModel.database);
  final InterconnectLinkPairingResult result = await pairWithInterconnectLink(
    repo: repo,
    link: link,
    localDeviceName: await resolveInterconnectDeviceName(
      appModel.platformServices.deviceInfo,
    ),
    pinProvider: () async =>
        context.mounted ? promptInterconnectPairPin(context) : null,
  );
  if (!context.mounted) return result is InterconnectLinkPaired;
  switch (result) {
    case InterconnectLinkPaired():
      _showSnackBar(context, t.sync_pair_success);
      return true;
    case InterconnectLinkPairingFailed(:final String reason):
      if (reason != 'cancelled') {
        _showSnackBar(context, interconnectPairFailureMessage(reason));
      }
      return false;
  }
}

/// host 侧：显示一次性配对二维码（含复制链接）。关闭即作废票据。
Future<void> showInterconnectPairQrDialog(
  BuildContext context,
  FushiSyncServerController controller,
) async {
  final FushiPairLink? link = await controller.createPairLink();
  if (!context.mounted) return;
  if (link == null) {
    _showSnackBar(context, t.sync_pair_qr_unavailable);
    return;
  }
  if (link.addresses.isEmpty) {
    controller.revokePairTicket();
    _showSnackBar(context, t.sync_pair_qr_no_address);
    return;
  }
  final String uri = link.toUri();
  try {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 420,
          insetPadding: EdgeInsets.all(tokens.spacing.card),
          scrollable: false,
          child: FushiModalSheetFrame(
            title: t.sync_pair_qr_title,
            scrollable: true,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            footerPadding: EdgeInsets.all(tokens.spacing.card),
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 二维码恒为白底黑码：深色主题下反色的码很多相机扫不出。
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(
                    data: uri,
                    size: 240,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
                if (link.deviceName != null)
                  Text(
                    link.deviceName!,
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                const SizedBox(height: 4),
                Text(t.sync_pair_qr_hint, textAlign: TextAlign.center),
              ],
            ),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () {
                    FlutterClipboard.copy(uri);
                    _showSnackBar(ctx, t.sync_pair_link_copied);
                  },
                  child: Text(t.sync_pair_link_copy),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(t.dialog_close),
                ),
              ],
            ),
          ),
        );
      },
    );
  } finally {
    controller.revokePairTicket();
  }
}

/// 粘贴配对链接。取消 → null；不是配对链接 → 提示并返回 null。
Future<FushiPairLink?> promptInterconnectPairLinkPaste(
  BuildContext context,
) async {
  final TextEditingController controller = TextEditingController();
  final String? raw = await showAppDialog<String>(
    context: context,
    builder: (BuildContext ctx) {
      final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
      return FushiDialogFrame(
        maxWidth: 460,
        insetPadding: EdgeInsets.all(tokens.spacing.card),
        scrollable: false,
        child: FushiModalSheetFrame(
          title: t.sync_pair_link_paste,
          scrollable: true,
          bodyPadding: EdgeInsets.fromLTRB(
            tokens.spacing.card,
            0,
            tokens.spacing.card,
            tokens.spacing.gap,
          ),
          footerPadding: EdgeInsets.all(tokens.spacing.card),
          body: FushiTextField(
            controller: controller,
            labelText: 'fushi://pair?…',
            autofocus: true,
          ),
          footer: Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            children: <Widget>[
              adaptiveDialogAction(
                context: ctx,
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.dialog_cancel),
              ),
              adaptiveDialogAction(
                context: ctx,
                isDefaultAction: true,
                onPressed: () => Navigator.pop(ctx, controller.text),
                child: Text(t.sync_pair_continue),
              ),
            ],
          ),
        ),
      );
    },
  );
  controller.dispose();
  if (raw == null || !context.mounted) return null;
  final FushiPairLink? link = FushiPairLink.tryParse(raw);
  if (link == null) _showSnackBar(context, t.sync_pair_link_invalid);
  return link;
}

/// 相机扫配对二维码（Android / iOS）。取消 → null。扫到的不是配对链接会继续扫，
/// 不把用户踢出去。
Future<FushiPairLink?> scanInterconnectPairQr(BuildContext context) {
  return Navigator.of(context).push<FushiPairLink>(
    MaterialPageRoute<FushiPairLink>(
      builder: (BuildContext ctx) => const _InterconnectPairScanPage(),
    ),
  );
}

class _InterconnectPairScanPage extends StatefulWidget {
  const _InterconnectPairScanPage();

  @override
  State<_InterconnectPairScanPage> createState() =>
      _InterconnectPairScanPageState();
}

class _InterconnectPairScanPageState extends State<_InterconnectPairScanPage> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final Barcode code in capture.barcodes) {
      final FushiPairLink? link = FushiPairLink.tryParse(code.rawValue);
      if (link == null) continue;
      _done = true;
      Navigator.of(context).pop(link);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.sync_pair_scan)),
      body: MobileScanner(
        onDetect: _onDetect,
        errorBuilder: (BuildContext ctx, MobileScannerException error) =>
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  t.sync_pair_scan_failed,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
      ),
    );
  }
}

/// 从本机候选列表为一台 host 组装**不带票据**的链接（写 NFC 贴纸用）：贴纸是长期
/// 物，只存地址与指纹；碰贴纸配对仍需 host 审批（非 LAN 还要 PIN）。
FushiPairLink? interconnectStickerLinkFor(
  List<FushiClientUrl> urls,
  FushiClientUrl host,
) {
  final String? hostId = host.hostId;
  if (hostId == null) return null;
  final List<FushiClientUrl> group = interconnectPeerAddressesOf(
    urls,
    host.url,
  );
  String? fingerprint;
  for (final FushiClientUrl u in group) {
    final String? fp = u.fingerprintSha256;
    if (fp != null && fp.isNotEmpty) fingerprint = fp;
  }
  return FushiPairLink(
    hostId: hostId,
    deviceName: host.deviceName,
    fingerprint: fingerprint,
    addresses: <InterconnectHostAddress>[
      for (final FushiClientUrl u in group)
        InterconnectHostAddress(
          url: u.url,
          kind: _kindForRank(interconnectUrlRank(u.url)),
        ),
    ],
  );
}

InterconnectAddressKind _kindForRank(int rank) => switch (rank) {
  0 => InterconnectAddressKind.lan,
  1 => InterconnectAddressKind.ipv6,
  2 => InterconnectAddressKind.overlay,
  4 => InterconnectAddressKind.p2p,
  _ => InterconnectAddressKind.public,
};

/// 把 [link]（必须不带票据）写进 NFC 贴纸（Android）。返回是否写入成功。
Future<void> writeInterconnectPairNfcTag(
  BuildContext context,
  FushiPairLink link,
) async {
  assert(!link.hasTicket, 'NFC 贴纸是长期物，绝不写一次性票据');
  final String uri = link.withoutTicket().toUri();
  _showSnackBar(context, t.sync_pair_nfc_write_hint);
  bool ok;
  try {
    ok =
        await _interconnectNfcChannel.invokeMethod<bool>(
          'writeUri',
          <String, Object?>{'uri': uri},
        ) ??
        false;
  } on PlatformException catch (e, st) {
    ErrorLogService.instance.log('InterconnectNfc.write', e, st);
    ok = false;
  }
  if (!context.mounted) return;
  _showSnackBar(context, ok ? t.sync_pair_nfc_written : t.sync_pair_nfc_failed);
}
