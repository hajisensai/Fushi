import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android 截屏识字的原生接线守卫（本仓 CI 不跑 Android JVM 单测，这里按源码钉住）：
///
/// - 「保持截屏会话」（反馈 9bdhVTgq3A / LHyeNKyYjH）：发起时先试保持着的会话，命中就
///   不登记「发起 Activity」、不起确认框；截完帧只摘 surface 不停投屏；系统停掉投屏时
///   收掉会话、回到每次申请；常驻通知带「停止」。
/// - 「截屏识字制卡带图」（反馈 Gz7z6Y6Mbr）：定格帧写缓存，点字时把路径 + 文本块 /
///   行框随 Intent 交给 `:popup` 查词窗，再经通道交给 Dart。
void main() {
  const String javaRoot = 'android/app/src/main/java/app/fushi/reader';
  String read(String name) => File('$javaRoot/$name').readAsStringSync();

  String body(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '找不到 $signature');
    return source.substring(start, source.indexOf('\n    }\n', start));
  }

  group('保持截屏会话', () {
    test('发起时先试保持着的会话：命中就不登记发起、不起确认框 Activity', () {
      final String launch = body(
        read('ScreenCaptureRequestActivity.java'),
        'static boolean launch(',
      );
      final int kept = launch.indexOf('ScreenOcrService.hasKeptSession()');
      final int reuse = launch.indexOf(
        'ScreenOcrService.captureWithKeptSession(language, labels)',
      );
      final int latch = launch.indexOf('LATCH.onLaunchRequested()');
      final int start = launch.indexOf('BackgroundActivityLauncher.start(');
      expect(kept, isNot(-1));
      expect(reuse, greaterThan(kept));
      expect(latch, greaterThan(reuse), reason: '命中会话的那次不能留下「发起被丢」欠账');
      expect(start, greaterThan(reuse));
      // 命中后：上流程锁、藏球、直接返回。
      final String hit = launch.substring(reuse, latch);
      expect(hit, contains('FloatingBallService.setCaptureHidden(true);'));
      expect(hit, contains('return true;'));
      expect(launch, contains('flowActive = true;'));
    });

    test('截完帧：保持时只摘 surface（不 stop 投屏），否则照旧释放', () {
      final String svc = read('ScreenOcrService.java');
      final String finish = body(svc, 'private void finishCapture()');
      expect(
        finish,
        contains(
          'if (keepSession && projection != null) {\n'
          '                pauseCapture();\n'
          '            } else {\n'
          '                releaseCapture();',
        ),
      );
      final String pause = body(svc, 'private void pauseCapture()');
      expect(pause, contains('virtualDisplay.setSurface(null);'));
      expect(pause, isNot(contains('projection.stop()')));
      final String begin = body(svc, 'private boolean beginKeptCapture(');
      expect(
        begin,
        contains('virtualDisplay.setSurface(imageReader.getSurface());'),
      );
      expect(begin, contains('virtualDisplay.resize('), reason: '转屏后虚拟屏跟着改尺寸');
      expect(
        begin,
        contains('captureHandler.postDelayed(maxWaitTimeout, MAX_WAIT_MS);'),
      );
    });

    test('流程收尾：会话保持就留着服务（常驻通知），否则停服务', () {
      final String finish = body(
        read('ScreenOcrService.java'),
        'private void finishFlow()',
      );
      expect(
        finish,
        contains(
          'if (keepSession && projection != null && virtualDisplay != null) {',
        ),
      );
      expect(finish, contains('notifyForeground(buildSessionNotification());'));
      expect(finish, contains('stopSelf();'));
    });

    test('系统停掉投屏：收掉会话，空闲时停服务；下次回到每次申请', () {
      final String svc = read('ScreenOcrService.java');
      expect(
        svc,
        contains(
          'mainHandler.post(() -> onProjectionStopped(current, inCapture));',
        ),
      );
      final String stopped = body(svc, 'private void onProjectionStopped(');
      expect(stopped, contains('keepSession = false;'));
      expect(stopped, contains('releaseCapture();'));
      expect(stopped, contains('if (inCapture || finished) finishFlow();'));
      // releaseCapture 必须清掉「可复用会话」。
      expect(
        body(svc, 'private void releaseCapture()'),
        contains('if (keptInstance == this) keptInstance = null;'),
      );
    });

    test('常驻通知说明会话在保持，带「停止」；停止 / 关掉选项会停会话', () {
      final String svc = read('ScreenOcrService.java');
      final String note = body(
        svc,
        'private Notification buildSessionNotification()',
      );
      expect(note, contains('.addAction(stopAction)'));
      expect(note, contains('setAction(ACTION_STOP_SESSION)'));
      expect(note, contains('LABEL_SESSION_NOTIFICATION'));
      expect(
        body(svc, 'public int onStartCommand('),
        contains('ACTION_STOP_SESSION.equals(intent.getAction())'),
      );
      final String options = read('ScreenOcrOptions.java');
      expect(
        options,
        contains('getBoolean(PREF_KEEP_SESSION, false)'),
        reason: '默认关',
      );
      expect(
        options,
        contains('if (!keepSession) ScreenOcrService.stopKeptSession();'),
      );
      expect(
        read('FloatingBallChannel.java'),
        contains('case "setScreenOcrOptions":'),
      );
    });
  });

  group('截屏识字制卡带图', () {
    test('识别成功后按选项把定格帧写进缓存；默认开', () {
      final String svc = read('ScreenOcrService.java');
      expect(
        svc,
        contains(
          'frozenFrame = bitmap;\n                    writeCardFrame(bitmap);',
        ),
      );
      expect(
        body(svc, 'private void writeCardFrame('),
        contains('if (!ScreenOcrOptions.cardImage(this)) return;'),
      );
      final String options = read('ScreenOcrOptions.java');
      expect(
        options,
        contains('getBoolean(PREF_CARD_IMAGE, true)'),
        reason: '默认开',
      );
      expect(options, contains('if (!cardImage) clearCardFrames(context);'));
      // 先写临时名再改名：查词窗读不到半个文件。
      expect(options, contains('tmp.renameTo(target)'));
      // 回收排在写盘之后（同一条单线程队列）。
      expect(
        body(svc, 'private void releaseFrame()'),
        contains('cardWriter.execute(frame::recycle);'),
      );
    });

    test('点字：路径 + 文本块 + 行框随 Intent 交给查词窗；块框来自 ML Kit 块之并', () {
      final String svc = read('ScreenOcrService.java');
      final String tap = body(svc, 'private void onSelectionTap(');
      expect(tap, contains('PopupDictFlutterActivity.EXTRA_CARD_IMAGE_PATH'));
      expect(
        tap,
        contains(
          'line.blockLeft, line.blockTop, line.blockRight, line.blockBottom',
        ),
      );
      expect(tap, contains('PopupDictFlutterActivity.EXTRA_CARD_IMAGE_LINE'));
      expect(
        svc,
        contains('blockBox.union(l.left, l.top, l.right, l.bottom);'),
      );
      final String activity = read('PopupDictFlutterActivity.kt');
      expect(
        activity,
        contains('intent.getIntArrayExtra(EXTRA_CARD_IMAGE_BLOCK)'),
      );
      expect(
        activity,
        contains('PopupEngineHolder.SourceBlock(block, offset, cardImage)'),
      );
      final String holder = read('PopupEngineHolder.kt');
      expect(holder, contains('map["cardImagePath"] = image.path'));
      expect(holder, contains('map["cardImageBlock"] = image.block.toList()'));
      expect(holder, contains('map["cardImageLine"] = image.line.toList()'));
    });

    test('Dart 制卡入口按卡图来源与偏好带 coverPath（四条链路共用 mixin / 覆盖窗委托）', () {
      final String mixin = File(
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ).readAsStringSync();
      expect(
        mixin,
        contains('if (!model.prefsRepo.screenOcrCardImage) return null;'),
      );
      expect(
        'coverPath: coverPath,'.allMatches(mixin).length,
        2,
        reason: '制卡与覆写都带图',
      );
      expect(
        File(
          'lib/src/pages/implementations/popup_dictionary_page.dart',
        ).readAsStringSync(),
        contains(
          'ScreenOcrCardImage? get miningCardImage => widget.cardImage;',
        ),
      );
      expect(
        File(
          'lib/src/media/audiobook/floating_lyric_lookup_host.dart',
        ).readAsStringSync(),
        contains('_cardImage = req.cardImage;'),
      );
      expect(
        File('lib/src/floating_ball/screen_ocr_picker.dart').readAsStringSync(),
        contains('cardImage: screenOcrCardImageForHit('),
      );
      final String overlay = File(
        'lib/src/lookup/overlay_bridge_handlers.dart',
      ).readAsStringSync();
      expect(overlay, contains('model.prefsRepo.screenOcrCardImage'));
      expect(
        overlay,
        contains('recordStats: false,'),
        reason: '委托路径统计由桥接层记，不能记两遍',
      );
    });
  });
}
