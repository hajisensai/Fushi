import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

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
    return adaptiveAlertDialog(
      context: context,
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
              HibikiTextField(
                autofocus: true,
                controller: _addressController,
                hintText: 'wss://',
                labelText: t.server_address,
                suffixIcon: HibikiIconButton(
                  size: 18,
                  tooltip: t.clear,
                  onTap: _addressController.clear,
                  icon: Icons.clear,
                ),
              ),
              const SizedBox(height: 10),
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
