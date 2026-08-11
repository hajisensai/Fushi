import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/utils/net/dictionary_dio.dart';

/// BUG-1493：**「更新这么慢，是网络原因吗」** —— 词典更新长时间没有任何可归因的反馈。
///
/// 查下来是两件独立的事，都在这里钉住：
///
/// 1. **词典链路根本不走代理，也没有任何超时。** 词典包与 `index.json` 全在
///    `github.com` / `raw.githubusercontent.com` / `huggingface.co` 上，而下载用的是裸
///    `Dio()`：默认 `HttpClient.findProxy` 为 null，既不读 `HTTP_PROXY`/`HTTPS_PROXY`
///    也不读 Windows 系统代理。同一台机器上浏览器秒开 GitHub，app 里下 30MB 的 Pixiv
///    词典却是直连——慢是真的慢，而且 Dio 默认无超时，服务器晾着连接就能无限挂住。
///
/// 2. **进度不可归因。** 下载期只有一句静态「正在更新 X…」，导入期没有任何一处再写进度
///    条（native 导入是一次不可分割的 FFI 调用，C++ 侧零回调），于是进度条定格在下载结束
///    时的满格一动不动，看起来就是卡死。
void main() {
  group('BUG-1493 出站装配：代理工厂 + 超时兜底', () {
    tearDown(() {
      dictionaryDioFactory = null;
    });

    test('未接线时回退裸 Dio，但超时仍被钉死（行为不倒退）', () async {
      dictionaryDioFactory = null;

      final Dio dio = await createDictionaryDio();
      addTearDown(dio.close);

      expect(dio.options.connectTimeout, kDictionaryConnectTimeout);
      expect(dio.options.receiveTimeout, kDictionaryStallTimeout,
          reason: '无超时 = 服务器晾着连接就能把用户永远留在「正在更新…」上');
    });

    test('接线后每次出站都经工厂拿 Dio（代理才可能生效）', () async {
      int calls = 0;
      dictionaryDioFactory = () async {
        calls++;
        return Dio();
      };

      final Dio first = await createDictionaryDio();
      addTearDown(first.close);
      final Dio second = await createDictionaryDio();
      addTearDown(second.close);

      expect(calls, 2, reason: '工厂被绕过 = 那一次请求又变回不走代理的直连');
    });

    test('工厂给的 Dio 也必须吃到超时预算（接了代理不能丢超时）', () async {
      dictionaryDioFactory = () async => Dio();

      final Dio dio = await createDictionaryDio();
      addTearDown(dio.close);

      expect(dio.options.connectTimeout, kDictionaryConnectTimeout);
      expect(dio.options.receiveTimeout, kDictionaryStallTimeout);
    });

    test('app 侧工厂装出的 Dio 用的是走代理解析层的 HttpClient adapter', () async {
      final Dio dio = await createProxiedDictionaryDio();
      addTearDown(dio.close);

      // 裸 Dio 的 adapter 是默认实例；接线后必须是我们自己装的那个（它把
      // applyAppProxy 配好的 HttpClient 交给 Dio）。
      final Dio bare = Dio();
      addTearDown(bare.close);
      expect(identical(dio.httpClientAdapter, bare.httpClientAdapter), isFalse);
    });

    test('installDictionaryDioFactory 幂等，把包内工厂接到 app 侧实现', () async {
      installDictionaryDioFactory();
      installDictionaryDioFactory();

      expect(dictionaryDioFactory, isNotNull);
      final Dio dio = await createDictionaryDio();
      addTearDown(dio.close);
      expect(dio.options.connectTimeout, kDictionaryConnectTimeout);
    });
  });

  group('BUG-1493 进度可归因：下载阶段', () {
    test('有 Content-Length 时报出已下载 / 总量', () {
      final String msg = dictionaryDownloadStageMessage(
        name: 'Pixiv Light [2026-02-01]',
        received: 5 * 1024 * 1024,
        total: 30 * 1024 * 1024,
      );

      expect(msg, contains('Pixiv Light [2026-02-01]'));
      expect(msg, contains('MB'), reason: '光说「正在更新」而不说下了多少，用户无法判断是慢还是挂了');
      // 分子分母都要在，且不是同一个数。
      expect(msg.contains('5'), isTrue);
      expect(msg.contains('30'), isTrue);
    });

    test('服务器不给 Content-Length 时不显示假分母', () {
      final String msg = dictionaryDownloadStageMessage(
        name: 'Pixiv Light [2026-02-01]',
        received: 1234,
        total: -1,
      );

      expect(msg, contains('Pixiv Light [2026-02-01]'));
      expect(msg, isNot(contains('/')), reason: 'total 未知时编一个分母比不显示更坏');
    });
  });

  group('BUG-1493 进度可归因：切进导入阶段', () {
    test('进度条归零（退化成不定态），文案切到导入中', () {
      final ValueNotifier<String> message =
          ValueNotifier<String>('downloading...');
      final ValueNotifier<double> progress = ValueNotifier<double>(1);
      addTearDown(message.dispose);
      addTearDown(progress.dispose);

      enterDictionaryImportStage(
        name: 'Pixiv Light [2026-02-01]',
        progressNotifier: message,
        downloadProgress: progress,
      );

      expect(progress.value, 0,
          reason: '不归零 → 进度条定格在下载结束时的满格，整个导入期一动不动 = 看起来卡死');
      expect(message.value, contains('Pixiv Light [2026-02-01]'));
      expect(message.value, isNot(equals('downloading...')));
    });
  });

  group('BUG-1493 回归守卫：词典链路不得再用裸 Dio', () {
    /// 剥掉注释再扫——本文件与被扫文件的文档注释里都写着这条根因的名字，不剥就是
    /// 一条稳定的假阳性（守卫的第一版正是这么红的）。
    String stripComments(String code) {
      final StringBuffer out = StringBuffer();
      bool inBlock = false;
      for (final String rawLine in code.split('\n')) {
        String line = rawLine;
        if (inBlock) {
          final int end = line.indexOf('*/');
          if (end < 0) continue;
          line = line.substring(end + 2);
          inBlock = false;
        }
        final int blockStart = line.indexOf('/*');
        if (blockStart >= 0) {
          line = line.substring(0, blockStart);
          inBlock = true;
        }
        final int lineComment = line.indexOf('//');
        if (lineComment >= 0) line = line.substring(0, lineComment);
        out.writeln(line);
      }
      return out.toString();
    }

    test('downloader / update service 的出站一律经 createDictionaryDio', () {
      final List<String> paths = <String>[
        '../packages/fushi_dictionary/lib/src/formats/dictionary_downloader.dart',
        '../packages/fushi_dictionary/lib/src/formats/dictionary_update_service.dart',
      ];

      for (final String p in paths) {
        final File file = File(p);
        expect(file.existsSync(), isTrue, reason: '守卫扫描目标不存在：$p');
        final String code = stripComments(file.readAsStringSync());

        // 唯一允许的裸构造是 `createDictionaryDio` 内部「工厂未接线」的回退
        // （`?? Dio()`）；别处再直接 new 一个就是绕开代理与超时装配。
        final Iterable<RegExpMatch> bare =
            RegExp(r'(?<!\?\?\s)\bDio\(\)').allMatches(code);
        expect(bare, isEmpty,
            reason: '$p 里出现裸 Dio()：那条请求会绕开代理与超时装配，'
                '正是 BUG-1493 的根因形态');

        expect(code.contains('createDictionaryDio'), isTrue,
            reason: '$p 必须经统一装配入口出站');
      }
    });

    test('剥注释器本身有效：注释里的裸构造不算命中，代码里的算', () {
      expect(stripComments('// 用裸 Dio() 出站\nfinal x = 1;'),
          isNot(contains('Dio()')));
      expect(stripComments('/// 回退裸 Dio()\nfinal Dio d = Dio();'),
          contains('Dio()'));
      expect(stripComments('/* 块注释 Dio() */\nfinal y = 2;'),
          isNot(contains('Dio()')));
    });
  });
}
