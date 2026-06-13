import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_shader_downloader.dart';
import 'package:path/path.dart' as p;

/// 可编程的假 [HttpClientAdapter]：按 URL 给出响应或抛错，记录被请求的 URL 顺序，
/// 用来验证「主源失败 → 镜像回退」与「非着色器内容被拒」。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  /// (url) → ResponseBody（正常）；抛 DioError 表示该 URL 请求失败。
  final FutureOr<ResponseBody> Function(String url) handler;

  /// 实际被请求过的 URL（按顺序），断言回退路径用。
  final List<String> requested = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String url = options.uri.toString();
    requested.add(url);
    return handler(url);
  }
}

ResponseBody _glslBody() {
  final List<int> bytes =
      '//!HOOK MAIN\n//!DESC Anime4K\nvec4 hook() {}\n'.codeUnits;
  return ResponseBody.fromBytes(bytes, 200, headers: <String, List<String>>{
    Headers.contentTypeHeader: <String>['text/plain'],
  });
}

ResponseBody _htmlBody() {
  final List<int> bytes = '<!DOCTYPE html><html>404</html>'.codeUnits;
  return ResponseBody.fromBytes(bytes, 200, headers: <String, List<String>>{
    Headers.contentTypeHeader: <String>['text/html'],
  });
}

Dio _dioWith(_FakeAdapter adapter) {
  final Dio dio = Dio(BaseOptions(responseType: ResponseType.bytes));
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  group('anime4kMirrorUrls', () {
    test('jsDelivr 多 CDN 节点优先、gh 代理前缀其次、raw 官方兜底（BUG-271 多镜像）', () {
      final List<String> urls =
          anime4kMirrorUrls('glsl/Restore/Anime4K_Clamp_Highlights.glsl');
      // 多镜像：单源抖动靠独立 CDN 节点 / 代理前缀兜底，根治整档偏偏失败一个。
      expect(urls.length, greaterThanOrEqualTo(5),
          reason: 'BUG-271：单一源不可达必须有多镜像可回退');
      expect(urls.first,
          startsWith('https://cdn.jsdelivr.net/gh/bloc97/Anime4K@master/'));
      expect(
          urls.first, endsWith('glsl/Restore/Anime4K_Clamp_Highlights.glsl'));
      expect(urls.any((String u) => u.contains('fastly.jsdelivr.net')), isTrue);
      expect(urls.any((String u) => u.contains('gcore.jsdelivr.net')), isTrue);
      expect(urls.any((String u) => u.contains('ghfast.top')), isTrue);
      expect(urls.any((String u) => u.contains('gh-proxy.com')), isTrue);
      expect(urls.last,
          'https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/Restore/Anime4K_Clamp_Highlights.glsl');
      expect(urls.toSet().length, urls.length);
    });

    test('含 + 的目录（Upscale+Denoise）所有镜像原样保留路径', () {
      final List<String> urls = anime4kMirrorUrls(
          'glsl/Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl');
      for (final String u in urls) {
        expect(u, contains('Upscale+Denoise'));
      }
    });
  });

  group('kAnime4kPresets', () {
    test('六个预设，id 稳定且唯一（Fast A/B/C + HQ A/B/C）', () {
      expect(kAnime4kPresets.length, 6);
      final Set<String> ids =
          kAnime4kPresets.map((Anime4kPreset e) => e.id).toSet();
      expect(ids, <String>{
        'mode_a_fast',
        'mode_b_fast',
        'mode_c_fast',
        'mode_a_hq',
        'mode_b_hq',
        'mode_c_hq',
      });
    });

    test('每个预设的 fileNames 去重保序，全部 .glsl', () {
      for (final Anime4kPreset preset in kAnime4kPresets) {
        expect(preset.fileNames, isNotEmpty);
        for (final String name in preset.fileNames) {
          expect(name, endsWith('.glsl'));
          expect(name, isNot(contains('/')));
        }
        // 去重：fileNames 长度 <= shaders 长度。
        expect(
            preset.fileNames.length, lessThanOrEqualTo(preset.shaders.length));
      }
    });

    test('Mode A (Fast) 链顺序符合官方模板（Clamp → Restore → Upscale …）', () {
      final Anime4kPreset a = kAnime4kPresets
          .firstWhere((Anime4kPreset e) => e.id == 'mode_a_fast');
      expect(
          a.shaders.map((Anime4kShaderFile s) => s.fileName).toList(), <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
    });
  });

  group('looksLikeGlslShader', () {
    test(
        '空 → false', () => expect(looksLikeGlslShader(const <int>[]), isFalse));
    test('含 //! 指令头 → true',
        () => expect(looksLikeGlslShader('//!HOOK MAIN\n'.codeUnits), isTrue));
    test('含 NUL（二进制）→ false',
        () => expect(looksLikeGlslShader(<int>[0x4D, 0x00, 0x5A]), isFalse));
    test(
        'HTML 错误页 → false',
        () =>
            expect(looksLikeGlslShader('<html>404</html>'.codeUnits), isFalse));
    test('开头是大段 MIT License 注释、//!HOOK 在数百字节之后 → true（回归）', () {
      // Anime4K 真实文件结构：license 注释块在前，mpv 指令在后。早期只探前 512 字节
      // 会把这种文件误判为非着色器而拒下载，这里钉死必须扫全文。
      final String license =
          List<String>.filled(40, '// MIT License blah blah').join('\n');
      final String shader = '$license\n\n//!HOOK MAIN\n//!DESC test\n';
      expect(shader.length, greaterThan(512));
      expect(looksLikeGlslShader(shader.codeUnits), isTrue);
    });
  });

  group('downloadAnime4kFiles', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('a4k_dl_'));
    tearDown(() => dir.deleteSync(recursive: true));

    const Anime4kPreset tiny = Anime4kPreset(
      id: 'tiny',
      name: 'Tiny',
      description: '',
      shaders: <Anime4kShaderFile>[
        Anime4kShaderFile('glsl/Restore/Anime4K_Clamp_Highlights.glsl'),
      ],
    );

    test('主源成功 → 落盘 + 不试镜像', () async {
      final _FakeAdapter adapter = _FakeAdapter((String url) => _glslBody());
      final Anime4kDownloadResult result = await downloadAnime4kFiles(
        tiny,
        targetDir: dir,
        dio: _dioWith(adapter),
      );
      expect(result.allOk, isTrue);
      expect(result.downloaded, <String>['Anime4K_Clamp_Highlights.glsl']);
      // 只请求了主源（jsDelivr），未回退。
      expect(adapter.requested.length, 1);
      expect(adapter.requested.single, contains('jsdelivr'));
      expect(
          File(p.join(dir.path, 'Anime4K_Clamp_Highlights.glsl')).existsSync(),
          isTrue);
    });

    test('第一个 jsDelivr 节点失败 → 回退第二个 jsDelivr 节点成功', () async {
      final _FakeAdapter adapter = _FakeAdapter((String url) {
        if (url.contains('cdn.jsdelivr.net')) {
          throw DioError(
            requestOptions: RequestOptions(path: url),
            type: DioErrorType.connectionError,
          );
        }
        return _glslBody();
      });
      final Anime4kDownloadResult result = await downloadAnime4kFiles(
        tiny,
        targetDir: dir,
        dio: _dioWith(adapter),
      );
      expect(result.allOk, isTrue);
      expect(adapter.requested.length, 2);
      expect(adapter.requested[0], contains('cdn.jsdelivr.net'));
      expect(adapter.requested[1], contains('fastly.jsdelivr.net'));
    });

    test('jsDelivr 全挂 → 回退 gh 代理前缀成功', () async {
      final _FakeAdapter adapter = _FakeAdapter((String url) {
        if (url.contains('jsdelivr')) {
          throw DioError(
            requestOptions: RequestOptions(path: url),
            type: DioErrorType.connectionError,
          );
        }
        return _glslBody();
      });
      final Anime4kDownloadResult result = await downloadAnime4kFiles(
        tiny,
        targetDir: dir,
        dio: _dioWith(adapter),
      );
      expect(result.allOk, isTrue);
      expect(adapter.requested.last, contains('ghfast.top'));
    });

    test('整组镜像一轮全挂 → 退避后重试整组镜像成功（BUG-271 瞬态抖动）', () async {
      int round = 0;
      final _FakeAdapter adapter = _FakeAdapter((String url) {
        if (url.contains('cdn.jsdelivr.net')) round++;
        if (round <= 1) {
          throw DioError(
            requestOptions: RequestOptions(path: url),
            type: DioErrorType.connectionError,
          );
        }
        return _glslBody();
      });
      final Anime4kDownloadResult result = await downloadAnime4kFiles(
        tiny,
        targetDir: dir,
        dio: _dioWith(adapter),
        retryBackoff: Duration.zero,
      );
      expect(result.allOk, isTrue, reason: '第一轮全挂、第二轮恢复，重试必须救回这个文件');
      expect(result.downloaded, <String>['Anime4K_Clamp_Highlights.glsl']);
    });

    test('maxRetries:0 关重试 → 一轮镜像全挂即失败（重试可关）', () async {
      final _FakeAdapter adapter = _FakeAdapter((String url) {
        throw DioError(
          requestOptions: RequestOptions(path: url),
          type: DioErrorType.connectionError,
        );
      });
      final Anime4kDownloadResult result = await downloadAnime4kFiles(
        tiny,
        targetDir: dir,
        dio: _dioWith(adapter),
        maxRetries: 0,
      );
      expect(result.allOk, isFalse);
      expect(adapter.requested.length,
          anime4kMirrorUrls(tiny.shaders.first.repoPath).length);
    });

    test('镜像返回 HTML（非着色器）→ 跳过继续回退', () async {
      final _FakeAdapter adapter = _FakeAdapter((String url) {
        if (url.contains('jsdelivr')) return _htmlBody();
        return _glslBody();
      });
      final Anime4kDownloadResult result = await downloadAnime4kFiles(
        tiny,
        targetDir: dir,
        dio: _dioWith(adapter),
      );
      expect(result.allOk, isTrue);
      // 所有 jsdelivr 节点返回 HTML 被拒，回退到第一个 gh 代理前缀成功。
      expect(adapter.requested.last, contains('ghfast.top'));
      final String content =
          File(p.join(dir.path, 'Anime4K_Clamp_Highlights.glsl'))
              .readAsStringSync();
      expect(content, contains('//!HOOK'));
    });

    test('所有镜像 + 所有重试轮都失败 → 计入 failed', () async {
      final _FakeAdapter adapter = _FakeAdapter((String url) {
        throw DioError(
          requestOptions: RequestOptions(path: url),
          type: DioErrorType.connectionError,
        );
      });
      final Anime4kDownloadResult result = await downloadAnime4kFiles(
        tiny,
        targetDir: dir,
        dio: _dioWith(adapter),
        maxRetries: 2,
        retryBackoff: Duration.zero,
      );
      expect(result.allOk, isFalse);
      expect(result.failed, <String>['Anime4K_Clamp_Highlights.glsl']);
      expect(result.downloaded, isEmpty);
      // 全部候选 × 三轮（1 + maxRetries:2）都试过才放弃。
      final int candidates =
          anime4kMirrorUrls(tiny.shaders.first.repoPath).length;
      expect(adapter.requested.length, candidates * 3);
    });

    test('已存在的文件 → 跳过下载、直接视作就绪', () async {
      File(p.join(dir.path, 'Anime4K_Clamp_Highlights.glsl'))
          .writeAsStringSync('//!HOOK MAIN');
      final _FakeAdapter adapter = _FakeAdapter((String url) => _glslBody());
      final Anime4kDownloadResult result = await downloadAnime4kFiles(
        tiny,
        targetDir: dir,
        dio: _dioWith(adapter),
      );
      expect(result.allOk, isTrue);
      expect(result.downloaded, <String>['Anime4K_Clamp_Highlights.glsl']);
      // 完全没发请求。
      expect(adapter.requested, isEmpty);
    });
  });

  group('shaderDownloadUrlsFor（粘链接下载：直链优先、镜像兜底）', () {
    test('GitHub blob 链接 → raw 直链优先，再 jsDelivr 多节点 / gh 代理兜底', () {
      final List<String> urls = shaderDownloadUrlsFor(
          'https://github.com/bloc97/Anime4K/blob/master/glsl/Restore/Anime4K_Restore_CNN_M.glsl');
      expect(urls.first,
          'https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/Restore/Anime4K_Restore_CNN_M.glsl');
      expect(urls.length, greaterThanOrEqualTo(5));
      expect(urls.any((String u) => u.contains('cdn.jsdelivr.net')), isTrue);
      expect(urls.any((String u) => u.contains('fastly.jsdelivr.net')), isTrue);
      expect(urls.any((String u) => u.contains('ghfast.top')), isTrue);
      expect(urls.any((String u) => u.contains('gh-proxy.com')), isTrue);
      expect(urls.toSet().length, urls.length);
    });

    test('raw.githubusercontent 链接 → 直链(原样)优先 + 多镜像兜底', () {
      final List<String> urls = shaderDownloadUrlsFor(
          'https://raw.githubusercontent.com/igv/FSRCNN-TensorFlow/master/FSRCNNX_x2_8-0-4-1.glsl');
      expect(urls.first,
          'https://raw.githubusercontent.com/igv/FSRCNN-TensorFlow/master/FSRCNNX_x2_8-0-4-1.glsl');
      expect(urls.length, greaterThanOrEqualTo(5));
      expect(urls[1], startsWith('https://cdn.jsdelivr.net/gh/'));
    });

    test('非 GitHub 直链 → 原样单条', () {
      const String url = 'https://example.com/cool/MyShader.glsl';
      expect(shaderDownloadUrlsFor(url), <String>[url]);
    });
  });

  group('shaderFileNameFromUrl（粘链接下载）', () {
    test('取 basename', () {
      expect(
        shaderFileNameFromUrl(
            'https://github.com/bloc97/Anime4K/blob/master/glsl/Restore/Anime4K_Restore_CNN_M.glsl'),
        'Anime4K_Restore_CNN_M.glsl',
      );
    });

    test('去查询串/锚点', () {
      expect(shaderFileNameFromUrl('https://x.com/a/Foo.hook?raw=1#frag'),
          'Foo.hook');
    });

    test('无 glsl/hook 扩展名 → 补 .glsl', () {
      expect(shaderFileNameFromUrl('https://x.com/a/shader'), 'shader.glsl');
    });

    test('非法字符折叠为 _', () {
      expect(shaderFileNameFromUrl('https://x.com/a/My Shader.glsl'),
          'My_Shader.glsl');
    });
  });

  // TODO-125：经典推荐着色器（RAVU/NNEDI3）整批删除——五档画质增强已覆盖普通用户，
  // 经典单文件着色器只对懂的人有意义，他们仍可走「粘贴链接下载」。守卫符号不再回潮。
  test('经典推荐着色器（RAVU/NNEDI3）符号已删除，不再内置', () {
    final String src = File('lib/src/media/video/video_shader_downloader.dart')
        .readAsStringSync();
    expect(src, isNot(contains('kRecommendedShaders')),
        reason: 'TODO-125 删经典推荐着色器目录');
    expect(src, isNot(contains('class RecommendedShader')),
        reason: 'TODO-125 删 RecommendedShader 模型');
    expect(src, isNot(contains('mpv-prescalers')),
        reason: 'TODO-125 删 RAVU/NNEDI3 直链');
    // 手动「粘贴链接下载」逃生口仍在（懂的人仍可自取经典着色器）。
    expect(src, contains('downloadShaderFromUrl'), reason: '粘贴链接下载逃生口必须保留');
    expect(src, contains('shaderDownloadUrlsFor'), reason: '链接镜像兜底逃生口必须保留');
  });

  group('downloadShaderFromUrl', () {
    test('空 URL → null（不下载）', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('shader_url_dl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await downloadShaderFromUrl('   ', targetDir: dir), isNull);
    });
  });
}
