import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';

/// 运行时错误码：源站返回了 Cloudflare 挑战页。[AidokuRuntimeException.challengeUrl]
/// 给出被拦的那一页，UI 可以在 WebView 里打开它完成验证后重试（BUG-1876）。
const String kAidokuCloudflareChallengeCode = 'CLOUDFLARE_CHALLENGE';

class AidokuRuntimeException implements Exception {
  const AidokuRuntimeException(
    this.code,
    this.message, {
    this.cause,
    this.challengeUrl,
    this.challengeUserAgent,
  });

  final String code;
  final String message;
  final Object? cause;

  /// 仅 [kAidokuCloudflareChallengeCode]：被 Cloudflare 拦下的请求 URL。
  final Uri? challengeUrl;

  /// 仅 [kAidokuCloudflareChallengeCode]：被拦那次请求实际发出的 User-Agent
  /// （源可自设覆盖默认身份）。解题 WebView 必须用它，`cf_clearance` 才绑对
  /// 身份；缺省时退回 [kAidokuUserAgent]。
  final String? challengeUserAgent;

  @override
  String toString() => 'AidokuRuntimeException($code): $message';
}

class AidokuPackageInspection {
  const AidokuPackageInspection({
    required this.manifest,
    required this.imports,
    required this.exports,
    required this.requiresWebView,
  });

  factory AidokuPackageInspection.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> runtime =
        (json['runtime'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    return AidokuPackageInspection(
      manifest:
          (json['manifest'] as Map<Object?, Object?>?)
              ?.cast<String, Object?>() ??
          const <String, Object?>{},
      imports: (runtime['imports'] as List<Object?>? ?? const <Object?>[])
          .map((Object? value) => value.toString())
          .toList(growable: false),
      exports: (runtime['exports'] as List<Object?>? ?? const <Object?>[])
          .map((Object? value) => value.toString())
          .toList(growable: false),
      requiresWebView: runtime['requiresWebView'] == true,
    );
  }

  final Map<String, Object?> manifest;
  final List<String> imports;
  final List<String> exports;
  final bool requiresWebView;

  Map<String, Object?> get sourceInfo =>
      (manifest['info'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
      const <String, Object?>{};

  List<AidokuListing> get listings =>
      (manifest['listings'] as List<Object?>? ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> value) =>
                AidokuListing.fromJson(value.cast<String, Object?>()),
          )
          .where((AidokuListing listing) => listing.id.isNotEmpty)
          .toList(growable: false);
}

class AidokuListing {
  const AidokuListing({
    required this.id,
    required this.name,
    this.kind = 'Default',
  });

  factory AidokuListing.fromJson(Map<String, Object?> json) => AidokuListing(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    kind: json['kind']?.toString() ?? 'Default',
  );

  final String id;
  final String name;
  final String kind;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'kind': kind,
  };
}

abstract interface class AidokuRuntime {
  Future<AidokuPackageInspection> inspect(String packagePath);

  Future<Map<String, Object?>> search(
    String packagePath, {
    String? query,
    int page = 1,
  });

  Future<Map<String, Object?>> getDetails(
    String packagePath,
    Map<String, Object?> manga,
  );

  Future<Map<String, Object?>> browse(
    String packagePath,
    AidokuListing listing, {
    int page = 1,
  });

  Future<List<Object?>> getPages(
    String packagePath,
    Map<String, Object?> manga,
    Map<String, Object?> chapter,
  );
}

/// Aidoku 扩展宿主的工厂。
///
/// **当前没有任何平台带宿主。** 两个宿主先后整条移除：
/// - iOS（内嵌 Rust 静态库 + MethodChannel）按 App Store 合规移除——Aidoku 的本质
///   是运行时加载第三方仓库提供的 WASM 扩展并执行，属于「下载并执行代码」，不能
///   上架（[StoreRestrictedCapability.onlineMangaSource]）。
/// - macOS（`Contents/Resources/aidoku_runtime/fushi-aidoku-runtime` 子进程）
///   连同 Rust CLI、打包 / 验证脚本与两条 workflow 的 bundle 步骤一并移除，
///   发布包里不再带 WASM 解释器。
///
/// Dart 侧的仓库 / 安装包 / 源浏览 / 书架条目层保留，全部经本工厂门控：
/// [isSupported] 恒 false，各页面据此隐藏 Aidoku 入口；旧版本留下的 Aidoku
/// 书架条目走 `OnlineMangaUnavailableReason.platformUnsupported`，不会崩在
/// 懒建运行时上。要重新接一个宿主，只需实现 [AidokuRuntime] 并在这里分派。
abstract final class AidokuRuntimeFactory {
  static bool get isSupported => false;

  static AidokuRuntime create() => throw const AidokuRuntimeException(
    'UNSUPPORTED_PLATFORM',
    'No Aidoku runtime host is bundled in this build',
  );
}
