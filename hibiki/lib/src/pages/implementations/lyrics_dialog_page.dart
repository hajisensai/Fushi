import 'package:flutter/material.dart';
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.76,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.lyrics_mode,
        leadingIcon: Icons.lyrics_outlined,
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

  List<Widget> get actions => [buildSearchButton()];

  Widget buildContent() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

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
                controller: _titleController,
                labelText: t.lyrics_title,
                suffixIcon: HibikiIconButton(
                  size: 18,
                  tooltip: t.clear,
                  onTap: _titleController.clear,
                  icon: Icons.clear,
                ),
              ),
              SizedBox(height: tokens.spacing.gap),
              HibikiTextField(
                controller: _artistController,
                labelText: t.lyrics_artist,
                suffixIcon: HibikiIconButton(
                  size: 18,
                  tooltip: t.clear,
                  onTap: _artistController.clear,
                  icon: Icons.clear,
                ),
              ),
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
