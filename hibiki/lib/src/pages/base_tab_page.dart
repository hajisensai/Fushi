import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// A template for a single media type's tab body content in the main menu.
abstract class BaseTabPage extends BasePage {
  const BaseTabPage({
    super.key,
  });

  @override
  BaseTabPageState<BaseTabPage> createState();
}

abstract class BaseTabPageState<T extends BaseTabPage> extends BasePageState {
  @override
  void initState() {
    super.initState();
    mediaType.tabRefreshNotifier.addListener(refresh);
  }

  @override
  void dispose() {
    mediaType.tabRefreshNotifier.removeListener(refresh);
    super.dispose();
  }

  void refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return mediaSource.buildHistoryPage();
  }

  MediaType get mediaType;

  MediaSource get mediaSource =>
      appModel.getCurrentSourceForMediaType(mediaType: mediaType);

  bool _isSearchBarFocused = false;

  void onFocusChanged({required bool focused}) async {
    _isSearchBarFocused = focused;

    if (!_isSearchBarFocused) {
      setState(() {});
    } else {
      if (!mediaSource.implementsSearch) {
        final focusScope = FocusScope.of(context);
        await mediaSource.onSearchBarTap(
          context: context,
          ref: ref,
          appModel: appModel,
        );
        setState(() {});
        focusScope.unfocus();
      }
    }
  }

  Widget buildChangeSourceButton() {
    return HibikiIconButton(
      size: textTheme.titleLarge?.fontSize,
      tooltip: t.change_source,
      icon: mediaSource.icon,
      onTap: () async {
        await showAppDialog(
          context: context,
          builder: (context) => MediaSourcePickerDialogPage(
            mediaType: mediaType,
          ),
        );
        mediaType.refreshTab();
      },
    );
  }

  Widget buildBackButton({
    required VoidCallback onTap,
  }) {
    return HibikiIconButton(
      size: textTheme.titleLarge?.fontSize,
      tooltip: t.back,
      icon: Icons.arrow_back,
      onTap: onTap,
    );
  }
}
