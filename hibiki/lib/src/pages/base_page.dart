import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// A page template which assumes use of [BasePageState] by which all pages
/// in the app will conveniently share base functionality.
abstract class BasePage extends ConsumerStatefulWidget {
  /// Create an instance of this page.
  const BasePage({super.key});

  // Abstract: every concrete page must supply its own state. A default
  // `=> BasePageState()` let `class Foo extends BasePage {}` compile and then
  // crash at runtime in the throwing build() (HBK-AUDIT-036).
  @override
  BasePageState<BasePage> createState();
}

/// A base class for providing all pages in the app with a collection
/// of shared functions and variables. In large part, this was implemented to
/// define shortcuts for common lengthy methods across UI code.
abstract class BasePageState<T extends BasePage> extends ConsumerState<T> {
  late final AppModel _cachedAppModel;
  late final CreatorModel _cachedCreatorModel;

  @override
  void initState() {
    super.initState();
    _cachedAppModel = ref.read(appProvider);
    _cachedCreatorModel = ref.read(creatorProvider);
  }

  /// Access the global model responsible for app-wide state management.
  /// Falls back to cached instance after dispose to prevent
  /// ProviderSubscription.read on closed subscription.
  AppModel get appModel {
    if (!mounted) return _cachedAppModel;
    return ref.watch(appProvider);
  }

  /// Access the global model responsible for creator state management.
  /// Falls back to cached instance after dispose.
  CreatorModel get creatorModel {
    if (!mounted) return _cachedCreatorModel;
    return ref.watch(creatorProvider);
  }

  /// Access the global model responsible for app-wide state management without
  /// listening to state updates. Safe to use in dispose().
  AppModel get appModelNoUpdate => _cachedAppModel;

  /// Access the global model responsible for creator state management without
  /// listening to state updates. Safe to use in dispose().
  CreatorModel get creatorModelNoUpdate => _cachedCreatorModel;

  /// Shortcut for accessing the app-wide theme-defined text theme.
  TextTheme get textTheme => Theme.of(context).textTheme;

  /// Shortcut for accessing the app-wide theme.
  ThemeData get theme => Theme.of(context);

  // build() is intentionally NOT implemented here — it is abstract (inherited
  // from State). Subclasses must provide it; a missing override is now a
  // compile error instead of a runtime UnimplementedError (HBK-AUDIT-036).

  /// Standard error message for use across the application.
  /// General widget for showing an error or a retry screen.
  ///
  /// 主文案是通用错误提示（i18n），原始异常串降级为折叠 detail（此前直接
  /// `'$error'` 上屏，用户看到的是 SqliteException(...) 原文）；调用方传了
  /// [refresh] 就渲染重试按钮（此前该参数被静默丢弃，页面没有任何恢复入口）。
  Widget buildError({
    Object? error,
    StackTrace? stack,
    Function()? refresh,
  }) {
    return Center(
      child: HibikiPlaceholderMessage(
        icon: Icons.error_outline,
        message: t.error_load_failed,
        detail: error != null ? '$error' : null,
        action: refresh != null
            ? FilledButton.tonalIcon(
                onPressed: () => refresh(),
                icon: const Icon(Icons.refresh),
                label: Text(t.retry),
              )
            : null,
      ),
    );
  }

  /// Standard loading circle for use across the application.
  Widget buildLoading() {
    return Center(
      child: SizedBox(
        height: 25,
        width: 25,
        child: adaptiveIndicator(
          context: context,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
