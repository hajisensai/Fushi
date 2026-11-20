/// Android「用其他应用打开」/「分享到 Fushi」导入书 / 漫画（拍板台 oeJzVRQ9p1）的契约。
///
/// 钉住四件事：收进来的文件怎么命名（导入层按扩展名分派、txt / cbz 的书名来自文件名）；
/// manifest 的 MIME 过滤器与 Dart 映射逐一对应、不收会污染打开列表的宽类型、不和查词的
/// 纯文字分享抢 SEND text/*；channel 名两端一致；收件箱取副本 → 改名 → 交出 → 导入后删副本。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/android_open_with.dart';
import 'package:fushi/src/media/import/external_book.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:path/path.dart' as p;

const String _manifestPath = 'android/app/src/main/AndroidManifest.xml';

/// manifest 里 `MainActivity` 的 `<activity>` 块。
String _mainActivityBlock() {
  final String manifest = File(_manifestPath).readAsStringSync();
  final Match? m = RegExp(
    r'<activity\s+android:name="\.MainActivity".*?</activity>',
    dotAll: true,
  ).firstMatch(manifest);
  expect(m, isNotNull, reason: 'MainActivity block not found');
  return m!.group(0)!;
}

/// [block] 里含 [action] 的每个 intent-filter 的文本。
List<String> _filtersWithAction(String block, String action) {
  return RegExp(r'<intent-filter>.*?</intent-filter>', dotAll: true)
      .allMatches(block)
      .map((Match m) => m.group(0)!)
      .where((String f) => f.contains('android:name="$action"'))
      .toList();
}

Set<String> _mimeTypes(String filter) => RegExp(
  r'android:mimeType="([^"]+)"',
).allMatches(filter).map((Match m) => m.group(1)!).toSet();

void main() {
  group('androidOpenWithFileName', () {
    test('原文件名带可收的扩展名：原样保留（书名来自文件名）', () {
      expect(
        androidOpenWithFileName(
          displayName: '吾輩は猫である.epub',
          mimeType: 'application/epub+zip',
        ),
        '吾輩は猫である.epub',
      );
      expect(
        androidOpenWithFileName(displayName: 'Vol 01.CBZ', mimeType: null),
        'Vol 01.CBZ',
      );
    });

    test('原文件名没有扩展名 / 只带临时后缀：按 MIME 补扩展名', () {
      expect(
        androidOpenWithFileName(
          displayName: '12345',
          mimeType: 'application/epub+zip',
        ),
        '12345.epub',
      );
      expect(
        androidOpenWithFileName(
          displayName: 'novel.tmp',
          mimeType: 'text/plain; charset=utf-8',
        ),
        'novel.txt',
      );
      expect(
        androidOpenWithFileName(
          displayName: '第1.5巻',
          mimeType: 'application/pdf',
        ),
        '第1.5巻.pdf',
      );
      expect(
        androidOpenWithFileName(displayName: null, mimeType: 'application/pdf'),
        'document.pdf',
      );
    });

    test('名字里的目录与非法字符去掉，不能写出副本目录', () {
      expect(
        androidOpenWithFileName(
          displayName: '../../shared_prefs/evil.epub',
          mimeType: 'application/epub+zip',
        ),
        'evil.epub',
      );
      expect(
        androidOpenWithFileName(
          displayName: r'a\b:c?.pdf',
          mimeType: 'application/pdf',
        ),
        'bc.pdf',
      );
      expect(
        androidOpenWithFileName(displayName: '..', mimeType: 'application/pdf'),
        'document.pdf',
      );
    });

    test('原名带非书的真扩展名：即使 MIME 是 text/plain 也拒收（桌面只收 .txt）', () {
      for (final String name in <String>['notes.json', 'a.srt', 'x.md']) {
        expect(
          androidOpenWithFileName(displayName: name, mimeType: 'text/plain'),
          isNull,
          reason: name,
        );
      }
    });

    test('cbr / cb7 不收：导入要外部 7-Zip，APK 里没有', () {
      expect(
        androidOpenWithFileName(
          displayName: 'v.cbr',
          mimeType: 'application/vnd.comicbook-rar',
        ),
        isNull,
      );
      expect(
        androidOpenWithFileName(displayName: 'v.cb7', mimeType: null),
        isNull,
      );
      expect(kAndroidOpenWithExtensions, isNot(contains('.cbr')));
      expect(kAndroidOpenWithExtensions, isNot(contains('.cb7')));
    });

    test('认不出是书：返回 null（.mokuro 只有入口文件，打不开）', () {
      expect(
        androidOpenWithFileName(
          displayName: 'a.zip',
          mimeType: 'application/zip',
        ),
        isNull,
      );
      expect(
        androidOpenWithFileName(displayName: 'v.mokuro', mimeType: null),
        isNull,
      );
      expect(
        androidOpenWithFileName(displayName: null, mimeType: null),
        isNull,
      );
    });

    test('超长文件名按 UTF-8 字节截断主干、保留扩展名（NAME_MAX 255 字节）', () {
      final String name = androidOpenWithFileName(
        displayName: '${'あ' * 300}.epub',
        mimeType: null,
      )!;
      expect(name.endsWith('.epub'), isTrue);
      expect(utf8.encode(name).length, lessThanOrEqualTo(130));
      expect(name, startsWith('あ' * 40));
    });

    test('截断不切断代理对（emoji）', () {
      final String name = androidOpenWithFileName(
        displayName: '${'a' * 118}😀😀.pdf',
        mimeType: null,
      )!;
      expect(name, '${'a' * 118}.pdf');
      expect(() => utf8.encode(name), returnsNormally);
      expect(name.runes.contains(0xFFFD), isFalse);
    });
  });

  group('manifest 与映射', () {
    test('收的扩展名都在桌面 open-with 白名单里', () {
      expect(
        kAndroidOpenWithExtensions.difference(kExternalBookOpenExtensions),
        isEmpty,
      );
    });

    test('VIEW 过滤器只收 content://，MIME 与映射逐一对应', () {
      final List<String> views = _filtersWithAction(
        _mainActivityBlock(),
        'android.intent.action.VIEW',
      ).where((String f) => f.contains('android:mimeType')).toList();
      expect(views, hasLength(1));
      expect(views.single, contains('android:scheme="content"'));
      expect(views.single, isNot(contains('android:scheme="file"')));
      expect(
        _mimeTypes(views.single),
        kAndroidOpenWithBookMimeTypes.keys.toSet(),
      );
    });

    test('SEND 过滤器不收 text/*（纯文字分享归查词弹窗），其余与映射一致', () {
      final List<String> sends = _filtersWithAction(
        _mainActivityBlock(),
        'android.intent.action.SEND',
      );
      expect(sends, hasLength(1));
      final Set<String> mimes = _mimeTypes(sends.single);
      expect(mimes.where((String m) => m.startsWith('text/')), isEmpty);
      expect(
        mimes,
        kAndroidOpenWithBookMimeTypes.keys
            .where((String m) => !m.startsWith('text/'))
            .toSet(),
      );
    });

    test('不收会把 Fushi 挂进所有文件打开列表的宽类型', () {
      final Set<String> all = _mimeTypes(_mainActivityBlock());
      for (final String wide in <String>[
        '*/*',
        'application/*',
        'application/octet-stream',
        'application/zip',
        'text/*',
      ]) {
        expect(all, isNot(contains(wide)), reason: wide);
      }
    });

    test('channel 名 Java / Dart 两端一致', () {
      final String java = File(
        'android/app/src/main/java/app/fushi/reader/constants/ChannelNames.java',
      ).readAsStringSync();
      expect(java, contains('OPEN_WITH = PREFIX + "/open_with"'));
      expect(FushiChannels.openWith.name, 'app.fushi.reader/open_with');
    });
  });

  group('AndroidOpenWithInbox', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel channel = MethodChannel('test/open_with');
    late Directory cache;
    late List<Object?> queue;

    setUp(() {
      cache = Directory.systemTemp.createTempSync('open_with_test');
      queue = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method != 'takeIncomingDocuments') return null;
            final List<Object?> taken = List<Object?>.of(queue);
            queue.clear();
            return taken;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });

    String stageCopy(String id) {
      final Directory dir = Directory(p.join(cache.path, id))..createSync();
      final File f = File(p.join(dir.path, 'incoming'))
        ..writeAsStringSync('book');
      return f.path;
    }

    test('取副本 → 按原名改名交出 → release 删掉副本目录', () async {
      final String copy = stageCopy('a');
      queue.add(<String, Object?>{
        'path': copy,
        'displayName': '猫.epub',
        'mimeType': 'application/epub+zip',
      });
      final List<String> books = <String>[];
      final AndroidOpenWithInbox inbox = AndroidOpenWithInbox(channel: channel);
      await inbox.start(
        onBook: (String path) async => books.add(path),
        onRejected: (_) => fail('should not reject'),
      );
      expect(books, <String>[p.join(cache.path, 'a', '猫.epub')]);
      expect(File(books.single).readAsStringSync(), 'book');

      await inbox.release(books.single);
      expect(Directory(p.join(cache.path, 'a')).existsSync(), isFalse);
      inbox.stop();
    });

    test('认不出是书：删副本、回报原名，不交出', () async {
      final String copy = stageCopy('b');
      queue.add(<String, Object?>{
        'path': copy,
        'displayName': 'dict.zip',
        'mimeType': 'application/zip',
      });
      final List<String?> rejected = <String?>[];
      final AndroidOpenWithInbox inbox = AndroidOpenWithInbox(channel: channel);
      await inbox.start(
        onBook: (String path) async => fail('should not deliver'),
        onRejected: rejected.add,
      );
      expect(rejected, <String?>['dict.zip']);
      expect(Directory(p.join(cache.path, 'b')).existsSync(), isFalse);
      inbox.stop();
    });

    test('同批某本导入抛异常：删它的副本并提示，其余照常交出', () async {
      queue
        ..add(<String, Object?>{
          'path': stageCopy('d1'),
          'displayName': 'bad.epub',
          'mimeType': 'application/epub+zip',
        })
        ..add(<String, Object?>{
          'path': stageCopy('d2'),
          'displayName': 'good.pdf',
          'mimeType': 'application/pdf',
        });
      final List<String> books = <String>[];
      final List<String?> rejected = <String?>[];
      final AndroidOpenWithInbox inbox = AndroidOpenWithInbox(channel: channel);
      await inbox.start(
        onBook: (String path) async {
          if (path.endsWith('bad.epub')) throw StateError('import failed');
          books.add(path);
        },
        onRejected: rejected.add,
      );
      expect(rejected, <String?>['bad.epub']);
      expect(Directory(p.join(cache.path, 'd1')).existsSync(), isFalse);
      expect(books, <String>[p.join(cache.path, 'd2', 'good.pdf')]);
      inbox.stop();
    });

    test('原生通知「有新文件」时再取一次；release 不碰别的路径', () async {
      final List<String> books = <String>[];
      final AndroidOpenWithInbox inbox = AndroidOpenWithInbox(channel: channel);
      await inbox.start(
        onBook: (String path) async => books.add(path),
        onRejected: (_) {},
      );
      expect(books, isEmpty);

      queue.add(<String, Object?>{
        'path': stageCopy('c'),
        'displayName': null,
        'mimeType': 'application/pdf',
      });
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(
              const MethodCall('incomingDocumentsAvailable'),
            ),
            (_) {},
          );
      expect(books, <String>[p.join(cache.path, 'c', 'document.pdf')]);

      final File foreign = File(p.join(cache.path, 'user.epub'))
        ..writeAsStringSync('x');
      await inbox.release(foreign.path);
      expect(foreign.existsSync(), isTrue);
      inbox.stop();
    });
  });
}
