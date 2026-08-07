import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_waveform_select.dart';
import 'package:fushi/src/mining/galgame_waveform_select_dialog.dart';
import 'package:fushi/utils.dart';

/// galgame 波形选区对话框 MD3 收口的 widget 行为守卫：
/// 走共享对话框骨架（HibikiDialogFrame + HibikiModalSheetFrame）、肯定动作
/// FilledButton 强调、文案走 i18n（t.game_waveform_select_title /
/// t.dialog_ok / t.dialog_cancel），同时锁「确定」返回选区、「取消」返回 null
/// 的既有契约不变。
void main() {
  // 1 秒 48kHz 16-bit 单声道：前 500ms 满幅方波、后 500ms 静音，让 VAD 有活干。
  GalAudioSlice buildSlice() {
    const int sampleRate = 48000;
    const PcmFormat fmt = PcmFormat(
      sampleRate: sampleRate,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
    );
    final Uint8List bytes = Uint8List(sampleRate * 2);
    final ByteData bd = ByteData.sublistView(bytes);
    for (int f = 0; f < sampleRate ~/ 2; f++) {
      bd.setInt16(f * 2, f.isEven ? 32767 : -32767, Endian.little);
    }
    return GalAudioSlice(pcm: bytes, format: fmt);
  }

  Future<GalWaveformRange?>? dialogResult;

  Future<void> openDialog(WidgetTester tester) async {
    dialogResult = null;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () {
              dialogResult =
                  showGalWaveformSelectDialog(context, slice: buildSlice());
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('走共享 MD3 骨架：frame + i18n 标题 + FilledButton 肯定动作',
      (WidgetTester tester) async {
    await openDialog(tester);
    expect(find.byType(HibikiDialogFrame), findsOneWidget);
    expect(find.byType(HibikiModalSheetFrame), findsOneWidget);
    expect(find.text(t.game_waveform_select_title), findsOneWidget);
    expect(find.widgetWithText(FilledButton, t.dialog_ok), findsOneWidget);
    expect(find.widgetWithText(TextButton, t.dialog_cancel), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('确定返回选区、取消返回 null（既有契约不变）', (WidgetTester tester) async {
    await openDialog(tester);
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();
    final GalWaveformRange? confirmed = await dialogResult!;
    expect(confirmed, isNotNull);
    expect(confirmed!.durationMs, greaterThan(0));

    await openDialog(tester);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(await dialogResult!, isNull);
  });
}
