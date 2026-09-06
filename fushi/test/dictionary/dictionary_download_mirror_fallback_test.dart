import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/utils/net/dictionary_dio.dart';
import 'package:fushi/src/utils/net/github_mirrors.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 按 URL 决定成功/失败的假适配器：记录每一次实际发出的请求。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.respond);

  /// 返回 null = 该请求抛连接超时；返回字节 = 该请求成功。
  final Uint8List? Function(String url) respond;
  final List<String> requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String url = options.uri.toString();
    requested.add(url);
    final Uint8List? body = respond(url);
    if (body == null) {
      throw DioError(
        requestOptions: options,
        type: DioErrorType.connectionTimeout,
      );
    }
    return ResponseBody.fromBytes(body, 200);
  }

  @override
  void close({bool force = false}) {}
}

/// BUG-2188：词典下载的候选回退与失败归因。
///
/// 为什么这些用例值得存在：用户点「下载 Wiktionary JA-ZH」，界面只给出
/// `下载失败：Wiktionary JA-ZH (中文): DioError [connection ...`——原因被截断、
/// 措辞还错成「导入失败」。修复分两层：**候选回退**（GitHub 托管的条目多试几个镜像）
/// 与**结构化归因**（失败带得出「连不上谁」）。下面逐层钉死。
void main() {
  setUp(() {
    dictionaryUrlCandidatesResolver = null;
    dictionaryDioFactory = null;
  });
  tearDown(() {
    dictionaryUrlCandidatesResolver = null;
    dictionaryDioFactory = null;
  });

  group('候选地址展开', () {
    test('未接线时只有原址——与接线前逐字等价', () {
      const String url = 'https://example.com/a.zip';
      expect(dictionaryDownloadCandidates(url), <String>[url]);
    });

    test('GitHub 托管的词典展开出镜像候选，原址恒在首位', () {
      installDictionaryUrlCandidatesResolver();
      const String url =
          'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/x.zip';
      final List<String> candidates = dictionaryDownloadCandidates(url);
      expect(candidates.first, url, reason: '直连必须先试：有代理时它最快也最权威');
      expect(candidates.length, kGitHubMirrorPrefixes.length + 1);
      expect(candidates.toSet().length, candidates.length, reason: '候选不得重复');
    });

    test('raw.githubusercontent 同样展开', () {
      installDictionaryUrlCandidatesResolver();
      const String url =
          'https://raw.githubusercontent.com/MarvNC/yomitan-dictionaries/master/dl/x.zip';
      expect(
        dictionaryDownloadCandidates(url).length,
        kGitHubMirrorPrefixes.length + 1,
      );
    });

    test(
        'huggingface 不展开——公共 GitHub 镜像对它实测一律 403，'
        'hf-mirror 对 /datasets/.../resolve/ 是 308 跳回原站', () {
      installDictionaryUrlCandidatesResolver();
      const String url =
          'https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/dict/ja/zh/wty-ja-zh.zip';
      expect(dictionaryDownloadCandidates(url), <String>[url]);
    });

    test('解析器返回空列表时仍回落到原址，绝不产出空候选', () {
      dictionaryUrlCandidatesResolver = (String _) => const <String>[];
      const String url = 'https://example.com/a.zip';
      expect(dictionaryDownloadCandidates(url), <String>[url]);
    });
  });

  group('失败归因', () {
    DioError dioError(DioErrorType type, {int? status}) => DioError(
          requestOptions: RequestOptions(path: '/x'),
          type: type,
          response: status == null
              ? null
              : Response<void>(
                  requestOptions: RequestOptions(path: '/x'),
                  statusCode: status,
                ),
        );

    test('连接超时 / 停顿超时 / 连接错误各自归位', () {
      expect(
        classifyDictionaryDownloadFailure(
          dioError(DioErrorType.connectionTimeout),
        ),
        DictionaryDownloadFailureKind.connectTimeout,
      );
      expect(
        classifyDictionaryDownloadFailure(
          dioError(DioErrorType.receiveTimeout),
        ),
        DictionaryDownloadFailureKind.stallTimeout,
      );
      expect(
        classifyDictionaryDownloadFailure(
          dioError(DioErrorType.connectionError),
        ),
        DictionaryDownloadFailureKind.connectionError,
      );
    });

    test('服务器已答复的状态错误不算传输失败——换镜像拿到的是同一份 404', () {
      final DioError e = dioError(DioErrorType.badResponse, status: 404);
      expect(
        classifyDictionaryDownloadFailure(e),
        DictionaryDownloadFailureKind.badResponse,
      );
      expect(isDictionaryTransportFailure(e), isFalse);
    });

    test('取消不算传输失败，也不该触发回退', () {
      final DioError e = dioError(DioErrorType.cancel);
      expect(
        classifyDictionaryDownloadFailure(e),
        DictionaryDownloadFailureKind.cancelled,
      );
      expect(isDictionaryTransportFailure(e), isFalse);
    });

    test('dio 把 SocketException 塞进 unknown 时仍认作连接错误', () {
      final DioError e = DioError(
        requestOptions: RequestOptions(path: '/x'),
        type: DioErrorType.unknown,
        error: const SocketException('no route'),
      );
      expect(
        classifyDictionaryDownloadFailure(e),
        DictionaryDownloadFailureKind.connectionError,
      );
      expect(isDictionaryTransportFailure(e), isTrue);
    });

    test('异常全文带上试过的地址与原始 cause', () {
      final DictionaryDownloadException e = DictionaryDownloadException(
        url: 'https://github.com/o/r/releases/download/v1/a.zip',
        attemptedUrls: <String>[
          'https://github.com/o/r/releases/download/v1/a.zip',
          'https://ghfast.top/https://github.com/o/r/releases/download/v1/a.zip',
        ],
        cause: dioError(DioErrorType.connectionTimeout),
      );
      expect(e.host, 'github.com');
      expect(e.kind, DictionaryDownloadFailureKind.connectTimeout);
      final String text = e.toString();
      expect(text, contains('ghfast.top'));
      expect(text, contains('connectTimeout'));
    });

    test('badResponse 带出状态码，供 UI 说清「返回了什么」', () {
      final DictionaryDownloadException e = DictionaryDownloadException(
        url: 'https://example.com/a.zip',
        attemptedUrls: <String>['https://example.com/a.zip'],
        cause: dioError(DioErrorType.badResponse, status: 403),
      );
      expect(e.statusCode, 403);
      expect(e.toString(), contains('403'));
    });
  });

  group('download() 的真实回退行为', () {
    late Directory tempDir;
    const String url =
        'https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/x.zip';

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dict_dl_test');
      installDictionaryUrlCandidatesResolver();
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// 装一个只对 [okUrlPart] 命中的假适配器，返回它记录到的请求序列。
    _ScriptedAdapter installAdapter(String? okUrlPart) {
      final _ScriptedAdapter adapter = _ScriptedAdapter(
        (String u) => okUrlPart != null && u.contains(okUrlPart)
            ? Uint8List.fromList(<int>[1, 2, 3, 4])
            : null,
      );
      dictionaryDioFactory = () async => Dio()..httpClientAdapter = adapter;
      return adapter;
    }

    test('直连超时后自动改用镜像，并真的落盘', () async {
      final _ScriptedAdapter adapter = installAdapter('ghfast.top');
      final File file = await DictionaryDownloader.download(
        url: url,
        tempDir: tempDir,
        progressNotifier: ValueNotifier<double>(0),
      );
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync(), <int>[1, 2, 3, 4]);
      expect(adapter.requested.first, url, reason: '第一跳必须是直连');
      expect(adapter.requested.length, 2, reason: '第二跳命中镜像后就不再往下试');
      expect(adapter.requested.last, contains('ghfast.top'));
    });

    test('全部候选都连不上时抛 DictionaryDownloadException，带齐试过的地址', () async {
      final _ScriptedAdapter adapter = installAdapter(null);
      await expectLater(
        DictionaryDownloader.download(
          url: url,
          tempDir: tempDir,
          progressNotifier: ValueNotifier<double>(0),
        ),
        throwsA(
          isA<DictionaryDownloadException>()
              .having(
                (DictionaryDownloadException e) => e.kind,
                'kind',
                DictionaryDownloadFailureKind.connectTimeout,
              )
              .having(
                (DictionaryDownloadException e) => e.host,
                'host',
                'github.com',
              )
              .having(
                (DictionaryDownloadException e) => e.attemptedUrls.length,
                'attempted',
                kGitHubMirrorPrefixes.length + 1,
              ),
        ),
      );
      expect(adapter.requested.length, kGitHubMirrorPrefixes.length + 1);
      expect(tempDir.listSync(), isEmpty, reason: '失败后不得留下半个包');
    });

    test('用户取消原样抛 DioError，不得被包成下载失败', () async {
      final _ScriptedAdapter adapter = _ScriptedAdapter((String _) => null);
      dictionaryDioFactory = () async => Dio()..httpClientAdapter = adapter;
      final CancelToken token = CancelToken()..cancel();
      Object? caught;
      try {
        await DictionaryDownloader.download(
          url: url,
          tempDir: tempDir,
          progressNotifier: ValueNotifier<double>(0),
          cancelToken: token,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isNot(isA<DictionaryDownloadException>()));
      expect(
        DictionaryDownloadController.isCancellation(caught!),
        isTrue,
        reason: '取消被包起来的话，用户点取消会被记成一条下载失败',
      );
    });
  });
}
