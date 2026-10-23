import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/web_browser/data/web_browser_store.dart';

/// 浏览器数据的全局入口；生产实现是 Drift（`DriftWebBrowserStore`），测试 override。
final Provider<WebBrowserStore> webBrowserStoreProvider =
    Provider<WebBrowserStore>(
      (Ref ref) => throw UnimplementedError('DriftWebBrowserStore 待接线'),
    );
