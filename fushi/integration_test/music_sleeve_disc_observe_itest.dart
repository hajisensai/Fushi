import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 观察用：歌词页分栏布局「唱片压在封面上」（有盘面扫描图 / 没有转银色 CD）与
/// 唱片布局真盘面中心挖孔的真实像素。素材全在临时目录现画，不碰用户库。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('歌词页唱片：分栏压封面 + 真盘面挖孔', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);

    final Directory dir = await Directory.systemTemp.createTemp('sleeve-disc');
    final String cover = '${dir.path}${Platform.pathSeparator}cover.png';
    // 盘面图放在与歌曲无关的临时目录：歌曲目录及其 scans 等子目录都会被按目录现找到，
    // 银色 CD 那张就拍不到。
    final Directory scans = await Directory.systemTemp.createTemp(
      'sleeve-scan',
    );
    final String disc = '${scans.path}${Platform.pathSeparator}disc.png';
    final String song = '${dir.path}${Platform.pathSeparator}song.wav';
    await tester.runAsync(() async {
      File(cover).writeAsBytesSync(await _paintPng(640, _paintCover));
      File(disc).writeAsBytesSync(await _paintPng(640, _paintDiscScan));
      File(song).writeAsBytesSync(_silentWav(seconds: 120));
    });

    final String userLayout = appModel.prefsRepo.musicLyricsLayout;
    final NavigatorState nav = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    Future<void> shoot(String layout, bool withDiscArt, String name) async {
      await appModel.prefsRepo.setMusicLyricsLayout(layout);
      MusicDiscArtIndex.instance.publish(<String, String>{
        if (withDiscArt) 'al-obs': disc,
      });
      unawaited(
        nav.push<void>(
          adaptivePageRoute<void>(
            context: nav.context,
            builder: (_) => const MusicLyricsPage(),
          ),
        ),
      );
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final ObserveShot shot = await captureFlutterFrame(tester, name);
      debugPrint('[sleeve-disc] $name saved=${shot.saved}');
      nav.pop();
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    try {
      await appModel.musicSession.engine.playQueue(<MusicPlayItem>[
        MusicPlayItem(
          trackUid: 'obs-1',
          path: song,
          title: 'Fly Me to the Star',
          artist: 'Starlight 99',
          albumUid: 'al-obs',
          coverPath: cover,
          durationMs: 120000,
        ),
      ]);
      await appModel.musicSession.engine.pause();
      await shoot('split', true, '01-split-real-disc');
      await shoot('split', false, '02-split-silver-cd');
      await shoot('disc', true, '03-disc-real-hole');
    } finally {
      await appModel.prefsRepo.setMusicLyricsLayout(userLayout);
      MusicDiscArtIndex.instance.publish(const <String, String>{});
      await appModel.musicSession.engine.stop();
    }
  });
}

Future<Uint8List> _paintPng(
  int side,
  void Function(ui.Canvas canvas, double side) paint,
) async {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  paint(ui.Canvas(rec), side.toDouble());
  final ui.Image img = await rec.endRecording().toImage(side, side);
  final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// 封面：浅底 + 左右两个「人物」色块，看压住了哪一边。
void _paintCover(ui.Canvas c, double s) {
  c.drawRect(
    ui.Rect.fromLTWH(0, 0, s, s),
    ui.Paint()..color = const ui.Color(0xFFE6F1FB),
  );
  c.drawRect(
    ui.Rect.fromLTWH(0, 0, s, s * 0.04),
    ui.Paint()..color = const ui.Color(0xFF185FA5),
  );
  c.drawCircle(
    ui.Offset(s * 0.35, s * 0.4),
    s * 0.12,
    ui.Paint()..color = const ui.Color(0xFFF0997B),
  );
  c.drawCircle(
    ui.Offset(s * 0.65, s * 0.4),
    s * 0.12,
    ui.Paint()..color = const ui.Color(0xFF444441),
  );
  c.drawRect(
    ui.Rect.fromLTWH(s * 0.18, s * 0.55, s * 0.32, s * 0.45),
    ui.Paint()..color = const ui.Color(0xFFE24B4A),
  );
  c.drawRect(
    ui.Rect.fromLTWH(s * 0.5, s * 0.55, s * 0.32, s * 0.45),
    ui.Paint()..color = const ui.Color(0xFF185FA5),
  );
}

/// 盘面扫描图：方形白底（扫描仪底板）上一张浅灰盘，中心孔是底板的白。
void _paintDiscScan(ui.Canvas c, double s) {
  final ui.Offset o = ui.Offset(s / 2, s / 2);
  c.drawRect(
    ui.Rect.fromLTWH(0, 0, s, s),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  c.drawCircle(o, s / 2, ui.Paint()..color = const ui.Color(0xFFCFCFCF));
  c.drawCircle(o, s * 0.17, ui.Paint()..color = const ui.Color(0xFFE4E4E4));
  c.drawCircle(o, s * 0.07, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  final ui.Paint mark = ui.Paint()..color = const ui.Color(0xFF6E6E6E);
  for (int i = 0; i < 6; i++) {
    final double a = i * math.pi / 3;
    c.drawRect(
      ui.Rect.fromCenter(
        center: o + ui.Offset(math.cos(a), math.sin(a)) * (s * 0.33),
        width: s * 0.06,
        height: s * 0.02,
      ),
      mark,
    );
  }
}

/// 单声道 16-bit 8kHz 静音 WAV。
Uint8List _silentWav({required int seconds}) {
  const int rate = 8000;
  final int dataLen = rate * 2 * seconds;
  final ByteData b = ByteData(44 + dataLen);
  void str(int off, String v) {
    for (int i = 0; i < v.length; i++) {
      b.setUint8(off + i, v.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  return b.buffer.asUint8List();
}
