import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/profile/profile_view_model.dart'
    show fushiDatabaseProvider;
import 'package:fushi/src/web_browser/data/drift_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';

/// 浏览器数据的全局入口；生产实现是 Drift（[DriftWebBrowserStore]，数据库取自
/// [fushiDatabaseProvider]），测试 override 成 `MemoryWebBrowserStore`。
final Provider<WebBrowserStore> webBrowserStoreProvider =
    Provider<WebBrowserStore>((Ref ref) {
      final DriftWebBrowserStore store = DriftWebBrowserStore(
        ref.watch(fushiDatabaseProvider),
      );
      ref.onDispose(store.dispose);
      return store;
    });
