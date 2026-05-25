import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// Used by the Reader Lyrics Source.
class LyricsDialogPage extends BasePage {
  /// Create an instance of this page.
  const LyricsDialogPage({
    required this.title,
    required this.artist,
    required this.onSearch,
    super.key,
  });

  /// Media title.
  final String title;

  /// Media artist.
  final String artist;

  /// On search action.
  final Function(String, String) onSearch;

  @override
  BasePageState createState() => _LyricsDialogPageState();
}

class _LyricsDialogPageState extends BasePageState<LyricsDialogPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;
  final ScrollController _contentScrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    _titleController = TextEditingController(text: widget.title);
    _artistController = TextEditingController(text: widget.artist);
  }

  @override
  void dispose() {
    _contentScrollController.dispose();
    _titleController.dispose();
    _artistController.dispose();
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

  List<Widget> get actions => [buildSearchButton()];

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
              TextField(
                autofocus: true,
                controller: _titleController,
                decoration: InputDecoration(
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  labelText: t.lyrics_title,
                  suffixIcon: HibikiIconButton(
                    size: 18,
                    tooltip: t.clear,
                    onTap: _titleController.clear,
                    icon: Icons.clear,
                  ),
                ),
              ),
              TextField(
                controller: _artistController,
                decoration: InputDecoration(
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  labelText: t.lyrics_artist,
                  suffixIcon: HibikiIconButton(
                    size: 18,
                    tooltip: t.clear,
                    onTap: _artistController.clear,
                    icon: Icons.clear,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildSearchButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSearch,
      child: Text(t.dialog_search),
    );
  }

  void executeSearch() async {
    widget.onSearch(
      _titleController.text,
      _artistController.text,
    );
  }
}
