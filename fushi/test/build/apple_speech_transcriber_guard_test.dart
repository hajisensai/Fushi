/// Apple 系统语音转录原生半边的静态守卫。
///
/// 与系统 OCR 那条同理：Swift 这边**没有任何 Dart 测试能碰到**，本机（Windows）连
/// 编都编不了。这里钉的是那些**错了不会报错**、或者只在某一类机器上才炸的地方。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  // 在**剥掉注释**的源码上判定。本仓注释极其详尽——这个文件的类文档里就逐字写着
  // `#if compiler(>=6.2)` 之类的字面量，不剥的话把实现里那一行改掉，守卫照样绿
  // （变异实测当场撞到过这条：3 个变异只红了 2 条）。
  final String swift = maskComments(
    File('apple/FushiSpeechTranscriber.swift').readAsStringSync(),
  );
  final String dart =
      File('lib/src/asr_host/apple_speech_channel.dart').readAsStringSync();
  final String iosDelegate =
      File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final String macosDelegate =
      File('macos/Runner/AppDelegate.swift').readAsStringSync();

  test('channel 名与 Dart 侧常量逐字一致', () {
    expect(dart, contains("MethodChannel('app.fushi.reader/apple_speech')"));
    expect(swift, contains('"app.fushi.reader/apple_speech"'));
  });

  test('iOS 与 macOS 两侧都注册了', () {
    expect(
      iosDelegate,
      contains('FushiSpeechTranscriber.register(binaryMessenger:'),
    );
    expect(
      macosDelegate,
      contains('FushiSpeechTranscriber.register('),
    );
  });

  test('两个 Xcode 工程都登记了这份 Swift（四处齐全）', () {
    for (final String path in <String>[
      'ios/Runner.xcodeproj/project.pbxproj',
      'macos/Runner.xcodeproj/project.pbxproj',
    ]) {
      final String pbx = File(path).readAsStringSync();
      expect(
        pbx,
        contains('path = ../../apple/FushiSpeechTranscriber.swift;'),
        reason: '$path 缺 PBXFileReference',
      );
      expect(
        pbx,
        contains(
          '/* FushiSpeechTranscriber.swift in Sources */ = {isa = PBXBuildFile;',
        ),
        reason: '$path 缺 PBXBuildFile',
      );
      expect(
        '/* FushiSpeechTranscriber.swift */,'.allMatches(pbx).length,
        1,
        reason: '$path 的 PBXGroup children 应恰好登记一次',
      );
      expect(
        '/* FushiSpeechTranscriber.swift in Sources */,'.allMatches(pbx).length,
        1,
        reason: '$path 的 Sources phase 应恰好登记一次',
      );
    }
  });

  test('两道版本闸门都在：编译期隔离 + 运行期可用性', () {
    // 编译期：SpeechAnalyzer 这批符号只存在于 Xcode 26 的 SDK。不隔离的话，本仓
    // Mac 开发机（Xcode 16.4）上整个工程编不过——而那台机器编不过是**本地**才发现
    // 的，CI 用 Xcode 26 反而一路绿。
    expect(swift, contains('#if compiler(>=6.2)'));
    expect(swift, contains('#else'));
    expect(swift, contains('#endif'));
    // 运行期：部署目标是 iOS 15.1 / macOS 13.4，绝大多数机器上这套 API 不存在。
    expect(swift, contains('#available(iOS 26.0, macOS 26.0, *)'));
  });

  test('老 SDK 分支把每个方法都兜住了，不留未定义符号', () {
    final int elseAt = swift.lastIndexOf('#else');
    final int endAt = swift.lastIndexOf('#endif');
    expect(elseAt, greaterThan(-1));
    expect(endAt, greaterThan(elseAt));
    final String fallback = swift.substring(elseAt, endAt);
    for (final String fn in <String>[
      'isAvailable',
      'localeList',
      'prepare',
      'transcribe',
    ]) {
      expect(
        fallback,
        contains(fn),
        reason: '老 Xcode 分支缺 $fn，那边会编不过',
      );
    }
    // 老分支必须回「不支持」，不能假装能跑。
    expect(fallback, contains('unsupported('));
  });

  test('payload 键名与 Dart 解析器一致', () {
    for (final String key in <String>[
      '"durationMs"',
      '"segments"',
      '"text"',
      '"startMs"',
      '"endMs"',
      '"tokens"',
    ]) {
      expect(swift, contains(key), reason: 'payload 缺键 $key');
      expect(dart, contains(key.replaceAll('"', "'")), reason: 'Dart 侧缺键 $key');
    }
  });

  test('句级时间来自 Result.range，词级来自 audioTimeRange', () {
    // 两级都要：句级拼 SRT，词级喂 transcript.tokens.jsonl。少一级下游就少一半能力。
    expect(swift, contains('value.range.start'));
    expect(swift, contains('value.range.end'));
    expect(swift, contains('.audioTimeRange'));
    expect(swift, contains('run.audioTimeRange'));
  });

  test('只收 isFinal 的结果，不把 volatile 中间态写进字幕', () {
    // 不过滤的话同一句会以逐步成形的形态重复出现在 SRT 里。
    expect(swift, contains('value.isFinal'));
  });

  test('整份文件一次喂进去（finishAfterFile），不是麦克风流', () {
    expect(
        swift, contains('start(inputAudioFile: file, finishAfterFile: true)'));
    expect(swift, contains('finalizeAndFinishThroughEndOfInput()'));
    expect(swift, contains('AVAudioFile(forReading:'));
  });

  test('三类不可用与「这次失败」分开，Dart 侧据此换引擎', () {
    for (final String code in <String>[
      'UNSUPPORTED_OS',
      'LOCALE_UNSUPPORTED',
      'ASSET_INSTALL_FAILED',
    ]) {
      expect(swift, contains(code));
      expect(dart, contains(code), reason: 'Dart 侧没把 $code 归到「不可用」');
    }
    expect(swift, contains('TRANSCRIBE_FAILED'));
    expect(swift, contains('CANCELLED'));
  });

  test('语言资产要显式装并预留，不指望它自己就位', () {
    expect(swift, contains('AssetInventory.assetInstallationRequest('));
    expect(swift, contains('downloadAndInstall()'));
    expect(swift, contains('AssetInventory.reserve(locale:'));
  });

  test('回调恰好一次：长任务有正常/抛错/取消三条出口', () {
    expect(swift, contains('if replied { return }'));
    expect(swift, contains('replied = true'));
  });
}
