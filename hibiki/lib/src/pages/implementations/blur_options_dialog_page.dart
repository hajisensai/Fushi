import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog when editing [BlurOptions].
class BlurOptionsDialogPage extends BasePage {
  /// Create an instance of this page.
  const BlurOptionsDialogPage({
    super.key,
  });

  @override
  BasePageState createState() => _BlurOptionsDialogPageState();
}

class _BlurOptionsDialogPageState extends BasePageState<BlurOptionsDialogPage> {
  late BlurOptions _blurOptions;
  late Color _pendingColor;
  late TextEditingController _blurrinessController;
  final ScrollController _contentScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _blurOptions = appModelNoUpdate.blurOptions;
    _pendingColor = _blurOptions.color;
    _blurrinessController =
        TextEditingController(text: _blurOptions.blurRadius.toString());
  }

  @override
  void dispose() {
    _contentScrollController.dispose();
    _blurrinessController.dispose();
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

  Widget buildContent() {
    return RawScrollbar(
      thickness: 3,
      thumbVisibility: true,
      controller: _contentScrollController,
      child: Padding(
        padding: Spacing.of(context).insets.onlyRight.normal,
        child: SingleChildScrollView(
          controller: _contentScrollController,
          child: SizedBox(
            width: desktopDialogContentWidth(MediaQuery.sizeOf(context).width),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ColorPicker(
                  pickerColor: _pendingColor,
                  onColorChanged: (color) async {
                    _pendingColor = color;
                  },
                  colorPickerWidth: 200,
                  pickerAreaHeightPercent: 0.8,
                ),
                TextField(
                  controller: _blurrinessController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    suffixText: t.unit_pixels,
                    suffixIcon: HibikiIconButton(
                      tooltip: t.reset,
                      size: 18,
                      onTap: () async {
                        _blurrinessController.text = '5.0';
                        FocusScope.of(context).unfocus();
                      },
                      icon: Icons.undo_outlined,
                    ),
                    labelText: t.player_option_blur_radius,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> get actions => [
        buildCancelButton(),
        buildSaveButton(),
      ];

  Widget buildCancelButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeCancel,
      child: Text(t.dialog_cancel),
    );
  }

  Widget buildSaveButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSave,
      child: Text(t.dialog_save),
    );
  }

  void executeCancel() async {
    Navigator.pop(context);
  }

  void executeSave() async {
    String blurrinessText = _blurrinessController.text;
    double? newBlurriness = double.tryParse(blurrinessText);

    if (newBlurriness != null && newBlurriness >= 0) {
      BlurOptions options = appModel.blurOptions;
      options.blurRadius = newBlurriness;
      options.color = _pendingColor;

      appModel.setBlurOptions(options);

      Navigator.pop(context);
    }
  }
}
