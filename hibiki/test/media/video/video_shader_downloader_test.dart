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
    test('生成 jsDelivr 优先、raw.githubusercontent 兜底的镜像顺序', () {
      final List<String> urls =
          anime4kMirrorUrls('glsl/Restore/Anime4K_Clamp_Highlights.glsl');
      expect(urls.length, 3);
      expect(urls.first,
          startsWith('https://cdn.jsdelivr.net/gh/bloc97/Anime4K@master/'));
      expect(
          urls.first, endsWith('glsl/Restore/Anime4K_Clamp_Highlights.glsl'));
      expect(urls[1], contains('ghfast.top'));
      expect(urls.last,
          'https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/Restore/Anime4K_Clamp_Highlights.glsl');
    });

    test('含 + 的目录（Upscale+Denoise）原样保留路径', () {
      final List<String> urls = anime4kMirrorUrls(
          'glsl/Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl');
      expect(urls.first, contains('Upscale+Denoise'));
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

    test('主源失败 → 回退第二镜像成功', () async {
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
      // 第一个（jsdelivr）失败，第二个（ghfast）成功。
      expect(adapter.requested.length, 2);
      expect(adapter.requested[0], contains('jsdelivr'));
      expect(adapter.requested[1], contains('ghfast.top'));
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
      // jsdelivr 返回 HTML 被拒，回退到 ghfast 成功。
      expect(adapter.requested.length, 2);
      // HTML 内容没被当成着色器写盘——最终文件是 GLSL。
      final String content =
          File(p.join(dir.path, 'Anime4K_Clamp_Highlights.glsl'))
              .readAsStringSync();
      expect(content, contains('//!HOOK'));
    });

    test('所有镜像失败 → 计入 failed', () async {
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
      );
      expect(result.allOk, isFalse);
      expect(result.failed, <String>['Anime4K_Clamp_Highlights.glsl']);
      expect(result.downloaded, isEmpty);
      // 三个镜像都试过。
      expect(adapter.requested.length, 3);
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
    test('GitHub blob 链接 → raw 直链优先，再 jsDelivr / ghfast 兜底', () {
      final List<String> urls = shaderDownloadUrlsFor(
          'https://github.com/bloc97/Anime4K/blob/master/glsl/Restore/Anime4K_Restore_CNN_M.glsl');
      expect(urls, <String>[
        'https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/Restore/Anime4K_Restore_CNN_M.glsl',
        'https://cdn.jsdelivr.net/gh/bloc97/Anime4K@master/glsl/Restore/Anime4K_Restore_CNN_M.glsl',
        'https://ghfast.top/https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/Restore/Anime4K_Restore_CNN_M.glsl',
      ]);
    });

    test('raw.githubusercontent 链接 → 直链(原样)优先', () {
      final List<String> urls = shaderDownloadUrlsFor(
          'https://raw.githubusercontent.com/igv/FSRCNN-TensorFlow/master/FSRCNNX_x2_8-0-4-1.glsl');
      expect(urls.first,
          'https://raw.githubusercontent.com/igv/FSRCNN-TensorFlow/master/FSRCNNX_x2_8-0-4-1.glsl');
      expect(urls, hasLength(3));
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

  group('kRecommendedShaders（推荐着色器目录）', () {
    test('非空，id 唯一', () {
      expect(kRecommendedShaders, isNotEmpty);
      final Set<String> ids =
          kRecommendedShaders.map((RecommendedShader e) => e.id).toSet();
      expect(ids.length, kRecommendedShaders.length);
    });

    test('全部是 GitHub raw 单文件直链，fileName 为 .hook/.glsl', () {
      for (final RecommendedShader s in kRecommendedShaders) {
        expect(s.url, startsWith('https://raw.githubusercontent.com/'),
            reason: '${s.id} 用 raw 直链（下载时 shaderDownloadUrlsFor 直链优先+镜像兜底）');
        final String ext = p.extension(s.fileName).toLowerCase();
        expect(<String>['.hook', '.glsl'].contains(ext), isTrue,
            reason: '${s.id} 落盘文件名扩展应是着色器');
      }
    });

    test('RAVU/NNEDI3 均来自维护中的 bjin/mpv-prescalers（实测可下）', () {
      expect(
        kRecommendedShaders
            .every((RecommendedShader s) => s.url.contains('mpv-prescalers')),
        isTrue,
      );
    });
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
