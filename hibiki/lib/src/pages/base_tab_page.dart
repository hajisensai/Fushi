import 'package:flutter/material.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';

/// A template for a single media type's tab body content in the main menu.
///
/// [BaseModuleTabPage] 的 MediaSource 特化子类：在共通 tab 生命周期之上
/// 绑定 [MediaType]（tabRefreshNotifier 刷新信号 + [MediaSource] 代理渲染）。
abstract class BaseTabPage extends BaseModuleTabPage {
  const BaseTabPage({
    super.key,
  });

  @override
  BaseTabPageState<BaseTabPage> createState();
}

abstract class BaseTabPageState<T extends BaseTabPage>
    extends BaseModuleTabPageState<T> {
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

  // refresh() 已上提到 BaseModuleTabPageState（守卫式 setState），此处继承。

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
    return FushiIconButton(
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
    return FushiIconButton(
      size: textTheme.titleLarge?.fontSize,
      tooltip: t.back,
      icon: Icons.arrow_back,
      onTap: onTap,
    );
  }
}
