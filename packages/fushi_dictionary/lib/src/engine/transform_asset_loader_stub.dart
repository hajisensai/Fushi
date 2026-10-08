/// 纯 Dart 宿主（无头服务端 / 纯 Dart 测试）的变形表资源读取：没有 Flutter 资源包，
/// [FushiDicts.preloadTransforms] 落到这里时明确报不支持，调用方应改用
/// `FushiDicts.preloadTransformsFrom` 传自己的读文件函数。
library;

/// 当前宿主的资源读取后端名（测试据此断言 Flutter 宿主选中了 rootBundle 分支）。
const String kTransformAssetBackend = 'none';

/// 按资源键读一份变形表。纯 Dart 宿主恒抛 [UnsupportedError]。
Future<String> loadBundledTransformAsset(String assetKey) =>
    Future<String>.error(
      UnsupportedError(
        'no Flutter asset bundle in this host; '
        'use FushiDicts.preloadTransformsFrom($assetKey)',
      ),
    );
