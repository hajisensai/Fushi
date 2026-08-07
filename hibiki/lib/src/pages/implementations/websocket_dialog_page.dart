import 'package:flutter/material.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';

/// Used by the Reader WebSocket Source.
class WebsocketDialogPage extends BasePage {
  /// Create an instance of this page.
  const WebsocketDialogPage({
    required this.address,
    required this.onConnect,
    super.key,
  });

  /// Server address.
  final String address;

  /// On connect action.
  final Function(String) onConnect;

  @override
  BasePageState createState() => _WebsocketDialogPageState();
}

class _WebsocketDialogPageState extends BasePageState<WebsocketDialogPage> {
  late final TextEditingController _addressController;
  final ScrollController _contentScrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    _addressController = TextEditingController(text: widget.address);
  }

  @override
  void dispose() {
    _contentScrollController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.server_address,
        leadingIcon: Icons.sensors_outlined,
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
        body: buildContent(),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }

  List<Widget> get actions => [buildConnectButton()];

  Widget buildContent() {
    return RawScrollbar(
      thickness: 3,
      thumbVisibility: true,
      controller: _contentScrollController,
      child: SingleChildScrollView(
        controller: _contentScrollController,
        child: SizedBox(
          width: desktopDialogContentWidth(MediaQuery.sizeOf(context).width),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FushiTextField(
                autofocus: true,
                controller: _addressController,
                hintText: 'wss://',
                labelText: t.server_address,
                suffixIcon: FushiIconButton(
                  size: 18,
                  tooltip: t.clear,
                  onTap: _addressController.clear,
                  icon: Icons.clear,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildConnectButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSearch,
      child: Text(t.dialog_connect),
    );
  }

  void executeSearch() async {
    widget.onConnect(
      _addressController.text,
    );
  }
}
