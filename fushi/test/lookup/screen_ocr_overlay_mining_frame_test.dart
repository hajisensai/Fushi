import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/screen_ocr_card_image.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板 EuOLprw_dV（选 b）：桌面截屏识字冻结层的制卡委托 [screenOcrOverlayMiningHandler]
/// 在「制卡时框选截图」开着时先经宿主的 `pickFrame` 框图——「×」回 `cancelled`、不制卡；
/// 覆盖已制卡片、请求已带卡图选择、偏好关着时都不弹框选。
///
/// 委托之后的制卡要真 Anki 仓库与 AppModel，这里只钉「弹不弹 / 放弃时回什么」：
/// 越过框选判定后第一次碰到的 AppModel 成员抛 [_Downstream]，以此证明走到了制卡那一步。
class _Downstream implements Exception {
  const _Downstream(this.member);
  final String member;
  @override
  String toString() => '_Downstream($member)';
}

class _FakePrefs implements PreferencesRepository {
  _FakePrefs({required this.cardImage, required this.frameOnMine});

  final bool cardImage;
  final bool frameOnMine;

  @override
  bool get screenOcrCardImage => cardImage;

  @override
  bool get screenOcrCardFrameOnMine => frameOnMine;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw _Downstream('prefs.${invocation.memberName}');
}

class _FakeApp implements AppModel {
  _FakeApp(this._prefs);

  final _FakePrefs _prefs;

  @override
  PreferencesRepository get prefsRepo => _prefs;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw _Downstream('app.${invocation.memberName}');
}

void main() {
  ScreenOcrCardImage source() => ScreenOcrCardImage(
    bytes: Uint8List.fromList(const <int>[1, 2, 3]),
    textBlock: const Rect.fromLTRB(10, 10, 60, 30),
    line: const Rect.fromLTRB(10, 10, 60, 20),
  );

  ({OverlayMiningHandler handler, List<ScreenOcrCardImage> picked}) build({
    bool cardImage = true,
    bool frameOnMine = true,
    MiningRequestOverrides? Function()? frame,
    ScreenOcrCardImage? image,
  }) {
    final List<ScreenOcrCardImage> picked = <ScreenOcrCardImage>[];
    final OverlayMiningHandler handler = screenOcrOverlayMiningHandler(
      model: _FakeApp(
        _FakePrefs(cardImage: cardImage, frameOnMine: frameOnMine),
      ),
      cardImage: image ?? source(),
      sentenceContext: '',
      pickFrame: (ScreenOcrCardImage s) async {
        picked.add(s);
        return frame?.call();
      },
    );
    return (handler: handler, picked: picked);
  }

  test('框选页点「×」：回 cancelled、不制卡，框的是这次点字的截图', () async {
    final ScreenOcrCardImage image = source();
    final built = build(image: image);
    final Map<String, Object?> reply = await built.handler(
      fields: <String, String>{'expression': '橋'},
    );
    expect(reply['cancelled'], isTrue);
    expect(reply['ankiConnect'], isFalse);
    expect(reply['noteId'], isNull);
    expect(built.picked, <ScreenOcrCardImage>[image]);
  });

  test('框好之后照常走制卡（不回 cancelled）', () async {
    final built = build(
      frame: () => const MiningRequestOverrides(
        crop: MiningImageCrop(
          pageIndex: 0,
          left: 0,
          top: 0,
          right: 1,
          bottom: 1,
        ),
      ),
    );
    await expectLater(
      built.handler(fields: <String, String>{'expression': '橋'}),
      throwsA(isA<_Downstream>()),
    );
    expect(built.picked, hasLength(1));
  });

  test('覆盖已制卡片不弹框选', () async {
    final built = build();
    await expectLater(
      built.handler(
        fields: <String, String>{'expression': '橋'},
        updateNoteId: 42,
      ),
      throwsA(isA<_Downstream>()),
    );
    expect(built.picked, isEmpty);
  });

  test('偏好关着（任一）不弹框选', () async {
    for (final ({bool cardImage, bool frameOnMine}) prefs
        in <({bool cardImage, bool frameOnMine})>[
          (cardImage: true, frameOnMine: false),
          (cardImage: false, frameOnMine: true),
        ]) {
      final built = build(
        cardImage: prefs.cardImage,
        frameOnMine: prefs.frameOnMine,
      );
      await expectLater(
        built.handler(fields: <String, String>{'expression': '橋'}),
        throwsA(isA<_Downstream>()),
      );
      expect(built.picked, isEmpty, reason: '$prefs');
    }
  });
}
