import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/web_browser/features/web_browser_feature.dart';

/// 浏览器功能的唯一装配点：浏览页 initState 时调一次，只保留 `available` 的。
/// 新功能 = 实现 [WebBrowserFeature] + 在这里加一行。
List<WebBrowserFeature> buildWebBrowserFeatures(WidgetRef ref) =>
    <WebBrowserFeature>[
      // 各功能实现在这里登记。
    ].where((WebBrowserFeature f) => f.available).toList();
