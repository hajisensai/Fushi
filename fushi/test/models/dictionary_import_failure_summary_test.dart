import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

DictionaryTaskFailure _importFailure(String name, [Object? error]) =>
    DictionaryTaskFailure(
      name: name,
      stage: DictionaryTaskStage.import,
      error: error ?? Exception('boom'),
    );

/// 造一个「连接超时」的下载失败，形状与真实链路一致（dio 5.1 的类名是 `DioError`）。
DictionaryTaskFailure _downloadTimeout(String name, String url) =>
    DictionaryTaskFailure(
      name: name,
      stage: DictionaryTaskStage.download,
      url: url,
      error: DictionaryDownloadException(
        url: url,
        attemptedUrls: <String>[url],
        cause: DioError(
          requestOptions: RequestOptions(path: url),
          type: DioErrorType.connectionTimeout,
        ),
      ),
    );

void main() {
  group('DictionaryImportManager.formatImportFailureSummary (BUG-082)', () {
    test('single failure names the one dictionary', () {
      final String msg = DictionaryImportManager.formatImportFailureSummary(
        <DictionaryTaskFailure>[_importFailure('辞書A')],
      );
      expect(msg, contains('辞書A'));
      expect(
        msg,
        isNot(contains(',')),
        reason: 'single failure should not look like a list',
      );
    });

    test('multiple failures list every failed dictionary in one message', () {
      final String msg = DictionaryImportManager.formatImportFailureSummary(
        <DictionaryTaskFailure>[
          _importFailure('辞書A'),
          _importFailure('辞書B'),
          _importFailure('辞書C'),
        ],
      );
      expect(msg, contains('辞書A'));
      expect(msg, contains('辞書B'));
      expect(msg, contains('辞書C'));
      // BUG-2188：多条汇总一行一条，每行都带自己的原因——旧实现把名字逗号连成一行、
      // 原因一个都不给。
      expect(
        msg.split('\n').length,
        4,
        reason: 'one header line plus one line per failure',
      );
    });
  });

  group('失败原因必须进得了文案（BUG-2188）', () {
    test('下载阶段失败说「下载失败」，不再谎报导入失败', () {
      final String msg = DictionaryImportManager.formatImportFailureSummary(
        <DictionaryTaskFailure>[
          _downloadTimeout(
            'Wiktionary JA-ZH',
            'https://huggingface.co/a/b.zip',
          ),
        ],
      );
      expect(msg.toLowerCase(), contains('download'));
      expect(msg.toLowerCase(), isNot(contains('import failed')));
    });

    test('导入阶段失败才说「导入失败」', () {
      final String msg = DictionaryImportManager.formatImportFailureSummary(
        <DictionaryTaskFailure>[_importFailure('辞書A')],
      );
      expect(msg.toLowerCase(), contains('import'));
    });

    test('连接超时的原因里点名了连不上的主机，而不是甩一串 DioError', () {
      final DictionaryTaskFailure failure = _downloadTimeout(
        'Wiktionary JA-ZH',
        'https://huggingface.co/a/b.zip',
      );
      expect(failure.reason, contains('huggingface.co'));
      expect(failure.reason, isNot(contains('DioError')));
    });

    test('全文诊断带上原始地址与原始异常，可整段复制去反馈', () {
      final DictionaryTaskFailure failure = _downloadTimeout(
        'Wiktionary JA-ZH',
        'https://huggingface.co/a/b.zip',
      );
      final String details = DictionaryImportManager.formatFailureDetails(
        <DictionaryTaskFailure>[failure],
      );
      expect(details, contains('https://huggingface.co/a/b.zip'));
      expect(details, contains('connectTimeout'));
    });

    test('多条失败的全文诊断逐条保留，不互相覆盖', () {
      final String details =
          DictionaryImportManager.formatFailureDetails(<DictionaryTaskFailure>[
        _downloadTimeout('A', 'https://huggingface.co/a.zip'),
        _importFailure('B', StateError('bad zip')),
      ]);
      expect(details, contains('https://huggingface.co/a.zip'));
      expect(details, contains('bad zip'));
    });
  });

  group('DictionaryImportException (BUG-082)', () {
    test('carries the underlying cause and memory flag', () {
      final cause = Exception('empty dictionary');
      final ex = DictionaryImportException(cause, isMemoryError: true);
      expect(ex.cause, same(cause));
      expect(ex.isMemoryError, isTrue);
      expect(ex.toString(), contains('empty dictionary'));
    });

    test('defaults isMemoryError to false', () {
      final ex = DictionaryImportException(Exception('x'));
      expect(ex.isMemoryError, isFalse);
    });
  });
}
