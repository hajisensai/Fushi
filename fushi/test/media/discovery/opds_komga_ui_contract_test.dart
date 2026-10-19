/// OPDS Komga 兼容的 UI 侧契约：连接测试的本地化结论（BUG-3519 / 3521）与
/// 发现页封面 provider 携带凭据头（BUG-3520）。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_server_probes.dart';
import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/external_provider.dart';

void main() {
  // AppCachedHttpImage 构造时会建磁盘缓存单例（经 path_provider 取临时目录）。
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('fushi_opds_cover');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => temp.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  group('连接测试结论文案', () {
    test('地址是网页：给本地化的「这是网页不是 OPDS 地址」', () {
      expect(
        opdsProbeFailureMessage(
          const OpdsWebPageFailure(providerId: 'opds-x', operation: 'browse'),
        ),
        t.discovery_opds_test_web_page,
      );
    });

    test('401 / 403：提示 Komga 填邮箱或用 API key', () {
      for (final ExternalProviderFailureKind kind
          in <ExternalProviderFailureKind>[
            ExternalProviderFailureKind.unauthorized,
            ExternalProviderFailureKind.forbidden,
          ]) {
        expect(
          opdsProbeFailureMessage(
            ExternalProviderFailure(
              providerId: 'opds-x',
              operation: 'browse',
              kind: kind,
              message: 'server rejected the configured credentials',
            ),
          ),
          t.discovery_opds_test_unauthorized,
        );
      }
    });

    test('其它失败沿用脱敏原因', () {
      expect(
        opdsProbeFailureMessage(
          const ExternalProviderFailure(
            providerId: 'opds-x',
            operation: 'browse',
            kind: ExternalProviderFailureKind.notFound,
            message: 'catalog endpoint not found',
          ),
        ),
        t.discovery_opds_test_failed(reason: 'catalog endpoint not found'),
      );
    });
  });

  group('发现页封面 provider', () {
    test('源给的凭据头原样交给图片加载器（BUG-3520）', () {
      final AppCachedHttpImage image = discoveryCoverImage(
        'http://localhost:25600/opds/v2/books/1/thumbnail',
        const <String, String>{'X-API-Key': 'k'},
      );
      expect(image.headers, <String, String>{'X-API-Key': 'k'});
    });

    test('空表 / null 按匿名处理', () {
      expect(
        discoveryCoverImage('https://cdn.example/a.jpg', null).headers,
        isNull,
      );
      expect(
        discoveryCoverImage(
          'https://cdn.example/a.jpg',
          const <String, String>{},
        ).headers,
        isNull,
      );
    });

    test('缓存键只看 URL：带不带头是同一张图，凭据不进键', () {
      final AppCachedHttpImage withHeaders = discoveryCoverImage(
        'http://localhost:25600/t',
        const <String, String>{'X-API-Key': 'k'},
      );
      final AppCachedHttpImage anonymous = discoveryCoverImage(
        'http://localhost:25600/t',
        null,
      );
      expect(withHeaders, anonymous);
      expect(withHeaders.cacheKey, isNull);
    });
  });
}
