import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：桌面 sidecar 与 Android 宿主给 Mihon / Aniyomi 扩展的 **network ABI**
/// 必须同形（BUG-2601）。
///
/// 扩展 APK 把宿主的 `eu.kanade.tachiyomi.network` 当 compileOnly：dex 里只有
/// 引用，运行期由宿主解析，缺一个符号就是 `NoSuchMethodError`——桌面端被包成
/// `BRIDGE_HTTP_500`，Android 端被扩展自己的 catch 吞成「0 条」。真实事故：
/// AnimeKai（yuzono `kotokai` v16.8）的剧集列表调 extensions-lib 16 的
/// `client.get(url)`，链接到合成方法
/// `RequestsKt.get$default(OkHttpClient, String, Headers, CacheControl,
/// Continuation, int, Object)`；两端宿主都只有 `GET()` / `POST()`。
///
/// 两份 Kotlin 分处两棵树（`third_party/m_extension_server/overlay/` 与
/// `fushi/android/app/src/main/kotlin/`）互不知情，只能靠这里锁住。真正的 JVM
/// 描述符由 sidecar 自己的反射测试钉（`RequestsTest.kt` 等，随
/// `build_desktop_runtime` 的 `:server:test` 跑）；本守卫只看两边源码是否都声明
/// 了同一组签名，以及 Dart 桥用到的 wire 方法名两端都有分发。
void main() {
  const String sidecarNetwork =
      '../third_party/m_extension_server/overlay/server/src/main/kotlin/'
      'eu/kanade/tachiyomi/network';
  const String androidNetwork =
      'android/app/src/main/kotlin/eu/kanade/tachiyomi/network';

  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '找不到 $path');
    return file.readAsStringSync();
  }

  test('suspend OkHttpClient.get / post 两端宿主都声明（lib 16 扩展直接链接它）', () {
    final RegExp getString = RegExp(
      r'suspend fun OkHttpClient\.get\(\s*url: String,\s*headers: Headers = DEFAULT_HEADERS,\s*cache: CacheControl = DEFAULT_CACHE_CONTROL,\s*\): Response',
    );
    final RegExp getHttpUrl = RegExp(
      r'suspend fun OkHttpClient\.get\(\s*url: HttpUrl,\s*headers: Headers = DEFAULT_HEADERS,\s*cache: CacheControl = DEFAULT_CACHE_CONTROL,\s*\): Response',
    );
    final RegExp post = RegExp(
      r'suspend fun OkHttpClient\.post\(\s*url: String,\s*headers: Headers = DEFAULT_HEADERS,\s*body: RequestBody = DEFAULT_BODY,\s*cache: CacheControl = DEFAULT_CACHE_CONTROL,\s*\): Response',
    );
    for (final String path in <String>[
      '$sidecarNetwork/Requests.kt',
      '$androidNetwork/Requests.kt',
    ]) {
      final String code = read(path);
      expect(
        getString.hasMatch(code),
        isTrue,
        reason: '$path 缺 suspend fun OkHttpClient.get(url: String, …)',
      );
      expect(
        getHttpUrl.hasMatch(code),
        isTrue,
        reason: '$path 缺 suspend fun OkHttpClient.get(url: HttpUrl, …)',
      );
      expect(
        post.hasMatch(code),
        isTrue,
        reason: '$path 缺 suspend fun OkHttpClient.post(url: String, …)',
      );
      // 默认参数是 ABI 的一部分：没有默认值就不会生成 `get$default` 合成方法，
      // 扩展链接的正是那个。
      expect(
        code.contains('awaitSuccess()'),
        isTrue,
        reason:
            '$path 的 suspend helper 必须经 awaitSuccess（非 2xx 抛 HttpException）',
      );
    }
  });

  test('rateLimit / rateLimitHost 的 Duration 重载两端宿主都有，且老的 TimeUnit 版仍在', () {
    final RegExp durationRateLimit = RegExp(
      r'fun OkHttpClient\.Builder\.rateLimit\(\s*permits: Int,\s*period: Duration = 1\.seconds,\s*\)',
    );
    final RegExp legacyRateLimit = RegExp(
      r'fun OkHttpClient\.Builder\.rateLimit\(\s*permits: Int,\s*period: Long = 1,\s*unit: TimeUnit = TimeUnit\.SECONDS,\s*\)',
    );
    final RegExp durationHost = RegExp(
      r'fun OkHttpClient\.Builder\.rateLimitHost\(\s*httpUrl: HttpUrl,\s*permits: Int,\s*period: Duration = 1\.seconds,\s*\)',
    );
    final RegExp legacyHost = RegExp(
      r'fun OkHttpClient\.Builder\.rateLimitHost\(\s*httpUrl: HttpUrl,\s*permits: Int,\s*period: Long = 1,\s*unit: TimeUnit = TimeUnit\.SECONDS,\s*\)',
    );
    for (final String root in <String>[sidecarNetwork, androidNetwork]) {
      final String rateLimit = read(
        '$root/interceptor/RateLimitInterceptor.kt',
      );
      expect(
        durationRateLimit.hasMatch(rateLimit),
        isTrue,
        reason: '$root 缺 Duration 版 rateLimit',
      );
      expect(
        legacyRateLimit.hasMatch(rateLimit),
        isTrue,
        reason: '$root 丢了 TimeUnit 版 rateLimit（lib 14 扩展还在用）',
      );
      final String host = read(
        '$root/interceptor/SpecificHostRateLimitInterceptor.kt',
      );
      expect(
        durationHost.hasMatch(host),
        isTrue,
        reason: '$root 缺 Duration 版 rateLimitHost',
      );
      expect(
        legacyHost.hasMatch(host),
        isTrue,
        reason: '$root 丢了 TimeUnit 版 rateLimitHost',
      );
    }
  });

  test('Dart 桥用到的作品网页 wire 方法两端宿主都分发', () {
    final String bridge = read(
      'lib/src/media/manga/mihon/mihon_bridge_runtime.dart',
    );
    final String android = read(
      'android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt',
    );
    final String sidecar = read(
      '../third_party/m_extension_server/upstream_src/server/src/main/kotlin/'
      'mextensionserver/impl/MihonInvoker.kt',
    );
    for (final String method in <String>['getMangaUrl', 'getAnimeUrl']) {
      expect(
        bridge.contains("'$method'"),
        isTrue,
        reason: 'Dart 桥不再调 $method 了？那本守卫要跟着改',
      );
      expect(
        android.contains('"$method" ->'),
        isTrue,
        reason: 'Android MihonChannelHandler 没分发 $method',
      );
      expect(
        sidecar.contains('"$method" ->'),
        isTrue,
        reason: 'sidecar MihonInvoker 没分发 $method',
      );
    }
  });
}
