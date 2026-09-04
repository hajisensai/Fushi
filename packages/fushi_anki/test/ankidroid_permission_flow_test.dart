import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

// BUG-2098：AnkiDroid 权限申请「发完就不管」+ 错误码域不通导致英文原文外泄。
//
// 三个各自独立的根因，这里一条一条钉死：
//  ① native `requestAnkidroidPermissions` 此前恒 success(true)——发起系统权限请求后
//     **不等用户答复**就返回，Dart 侧紧接着查 provider，于是权限对话框还在屏幕上时
//     错误已经报完了。现在它返回真实终态，Dart 侧 `_ensurePermission` 据此短路，
//     **非授权状态下一个 provider 方法都不该被调到**。
//  ② native 发的裸码 `PERMISSION_DENIED` 与本地化表查的 `ANKI_PERMISSION_DENIED`
//     是两个不相通的码域，只有制卡路径做了转换。fetch 路径直传裸码，于是
//     `localizeAnkiFetchError` 恒查不中、回退显示 provider 的英文原文——中文文案
//     明明早写好了却永远用不上。分类现在收口于 `classifyPlatformError`，fetch 也走它。
//  ③ 「不再询问」与「AnkiDroid 没装」必须与普通拒绝分开：前两者再点一百次也不会弹框，
//     沿用「请在刚弹出的对话框中允许」那句话等于把用户堵死在设置页里。

const MethodChannel _channel = MethodChannel('app.fushi.reader/anki');

void _mockChannel(Future<Object?> Function(MethodCall call) responder) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, responder);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // fetchConfiguration 成功路径会经 updateSettings 落 SharedPreferences；不给内存桩
  // 就是 MissingPluginException，与被测行为无关。
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('BUG-2098 ①：权限没到手就不许碰 provider', () {
    for (final MapEntry<String, String> entry in <String, String>{
      'denied': AnkiErrorCode.permissionDenied,
      'permanently_denied': AnkiErrorCode.permissionPermanentlyDenied,
      'unavailable': AnkiErrorCode.ankiDroidUnavailable,
      'no_activity': AnkiErrorCode.permissionDenied,
    }.entries) {
      test('native 回 "${entry.key}" → 不查 provider，分类成 ${entry.value}',
          () async {
        final List<String> calls = <String>[];
        _mockChannel((MethodCall call) async {
          calls.add(call.method);
          if (call.method == 'requestAnkidroidPermissions') return entry.key;
          return null;
        });

        final AnkiFetchResult result =
            await AnkiRepository().fetchConfiguration();

        expect(result, isA<AnkiFetchError>());
        expect((result as AnkiFetchError).code, entry.value,
            reason: '错误码必须过 classifyPlatformError，否则本地化表查不中');
        // 关键断言：权限没拿到就一个 provider 方法都不该发出去。此前的
        // fire-and-forget 契约下 getDecks/getModelList 会照发不误。
        expect(calls, <String>['requestAnkidroidPermissions'],
            reason: '权限未授予时不得继续访问 AnkiDroid provider');
      });
    }

    test('native 回 "granted" → 正常继续查 provider', () async {
      final List<String> calls = <String>[];
      _mockChannel((MethodCall call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'requestAnkidroidPermissions':
            return 'granted';
          case 'getDecks':
            return <Object?, Object?>{1: 'Mining'};
          case 'getModelList':
            return <Object?, Object?>{2: 'Lapis'};
          case 'getFieldList':
            return <Object?>['Word'];
        }
        return null;
      });

      final AnkiFetchResult result = await AnkiRepository().fetchConfiguration();

      expect(result, isA<AnkiFetchSuccess>());
      expect(calls, contains('getDecks'));
    });

    test('旧 native / 无此方法的桩（true / null）仍视为已授权，向后兼容', () async {
      for (final Object? legacy in <Object?>[true, null]) {
        final List<String> calls = <String>[];
        _mockChannel((MethodCall call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'requestAnkidroidPermissions':
              return legacy;
            case 'getDecks':
              return <Object?, Object?>{1: 'Mining'};
            case 'getModelList':
              return <Object?, Object?>{2: 'Lapis'};
            case 'getFieldList':
              return <Object?>['Word'];
          }
          return null;
        });

        expect(
            await AnkiRepository().fetchConfiguration(), isA<AnkiFetchSuccess>(),
            reason: '旧契约返回值 $legacy 不得被判成拒绝');
        expect(calls, contains('getDecks'));
      }
    });
  });

  group('BUG-2098 ②：错误码收口于 classifyPlatformError', () {
    test('native 裸码全部映射到带 ANKI_ 前缀的稳定码', () {
      expect(
        AnkiRepository.classifyPlatformError(
            PlatformException(code: 'PERMISSION_DENIED')),
        AnkiErrorCode.permissionDenied,
      );
      expect(
        AnkiRepository.classifyPlatformError(
            PlatformException(code: 'PERMISSION_PERMANENTLY_DENIED')),
        AnkiErrorCode.permissionPermanentlyDenied,
      );
      expect(
        AnkiRepository.classifyPlatformError(
            PlatformException(code: 'ANKI_NOT_INSTALLED')),
        AnkiErrorCode.ankiDroidUnavailable,
      );
      expect(
        AnkiRepository.classifyPlatformError(
            PlatformException(code: AnkiErrorCode.collectionUnavailable)),
        AnkiErrorCode.collectionUnavailable,
      );
    });

    test('三个权限态互不相等——合并了就等于给用户指错路', () {
      expect(AnkiErrorCode.permissionDenied,
          isNot(AnkiErrorCode.permissionPermanentlyDenied));
      expect(AnkiErrorCode.permissionDenied,
          isNot(AnkiErrorCode.ankiDroidUnavailable));
      expect(AnkiErrorCode.permissionPermanentlyDenied,
          isNot(AnkiErrorCode.ankiDroidUnavailable));
    });

    test('漏了守卫时 provider 的英文原文仍按 message 兜底分类', () {
      expect(
        AnkiRepository.classifyPlatformError(PlatformException(
          code: 'ANKI_PROVIDER_ERROR',
          message: 'Permission not granted for: CardContentProvider.query '
              '/decks (app.fushi.reader)',
        )),
        AnkiErrorCode.permissionDenied,
      );
    });

    test('无关异常保持未分类（null），不冒领', () {
      expect(
        AnkiRepository.classifyPlatformError(
            PlatformException(code: 'ADD_NOTE_FAILED', message: 'boom')),
        isNull,
      );
    });

    test('fetch 失败带回稳定码而非裸码', () async {
      _mockChannel((MethodCall call) async {
        if (call.method == 'requestAnkidroidPermissions') return 'granted';
        throw PlatformException(
          code: 'PERMISSION_DENIED',
          message: 'AnkiDroid permission not granted. Please grant and retry.',
        );
      });

      final AnkiFetchResult result = await AnkiRepository().fetchConfiguration();

      expect(result, isA<AnkiFetchError>());
      expect((result as AnkiFetchError).code, AnkiErrorCode.permissionDenied,
          reason: '直传 e.code 会让本地化表恒查不中，英文原文外泄给用户');
    });
  });

  group('BUG-2098 ③：native 侧权限链路（源码扫描守卫）', () {
    // 宿主上没有真 AnkiDroid，Java 侧行为无法运行时验证；退而扫源码，钉住三条
    // 「回归了就直接复发本 bug」的结构不变式。
    final File handler = File(
      '../../fushi/android/app/src/main/java/app/fushi/reader/'
      'AnkiChannelHandler.java',
    );
    final File activity = File(
      '../../fushi/android/app/src/main/java/app/fushi/reader/'
      'MainActivity.java',
    );

    test('两个 native 文件都在预期路径（守卫本身没漂）', () {
      expect(handler.existsSync(), isTrue, reason: '路径漂了：${handler.path}');
      expect(activity.existsSync(), isTrue, reason: '路径漂了：${activity.path}');
    });

    test('权限请求把 Result 挂起，等 onRequestPermissionsResult 再 resolve', () {
      final String src = handler.readAsStringSync();
      expect(src.contains('pendingPermissionResult = result;'), isTrue,
          reason: '不挂起就等于回到「发完就返回」，权限框还开着错误已经报完');
      expect(src.contains('boolean onRequestPermissionsResult('), isTrue,
          reason: '没有回调入口，授权结果永远回不到 Dart');
    });

    test('MainActivity 转发系统权限回调——全 app 曾经一个实现都没有', () {
      final String src = activity.readAsStringSync();
      expect(
        src.contains('ankiChannelHandler.onRequestPermissionsResult('),
        isTrue,
        reason: 'Activity 不转发，handler 里挂起的 Result 就永远等不到结果',
      );
    });

    test('永久拒绝与普通拒绝在 native 侧被分开', () {
      final String src = handler.readAsStringSync();
      expect(src.contains('canAskPermissionAgain('), isTrue,
          reason: '不查 rationale 就分不出「还能再问」和「不再询问」');
      expect(src.contains('PERM_PERMANENTLY_DENIED'), isTrue);
      expect(src.contains('PERM_UNAVAILABLE'), isTrue,
          reason: 'AnkiDroid 没装时该权限根本不存在，报「去设置授权」是误导');
    });

    test('requirePermission 守卫不再自己发起请求（避免一次操作弹两次框）', () {
      final String src = handler.readAsStringSync();
      final int idx = src.indexOf('private boolean requirePermission(');
      expect(idx, greaterThanOrEqualTo(0));
      final String body = src.substring(idx, idx + 600);
      expect(body.contains('requestPermission('), isFalse,
          reason: '发起与等待是 requestAnkidroidPermissions 的单一职责；'
              '守卫里再发一次既弹两次框，那次请求也无人等待');
    });
  });
}
