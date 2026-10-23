// 复习页片段放大视图 + 从复习页跳转的编辑页实测（Windows runner，手动跑）。
//
// 种一张带视频片段（Picture 字段 `[sound:clip.mp4]`）的 Fushi 卡片：
// 1. 放大视图：卡面与对话框同时挂同一个 media_kit 画面——两处 Texture 是否同一个 id、
//    对话框里画面是否在走、关掉对话框后卡面画面是否还在。
// 2. 编辑页（复习页顶栏「编辑」跳转）：改字段触发实时预览重渲染，量预览 WebView 是否
//    整页重载（页内标记是否还在）、输入框是否还持焦点；比较编辑页与复习页片段的
//    显示尺寸 / 纹理尺寸 / 过滤质量（「比复习页糊」的判据）。
// 结果打 `[srs-media-editor]` 行，截图落证据目录。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_review_media_editor_itest.dart `
//     -DartDefine @('FUSHI_PROBE_CLIP=C:/path/clip720.mp4')
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_video_clip.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_preview.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _clip = String.fromEnvironment('FUSHI_PROBE_CLIP');

void _log(String line) {
  final String full = '[srs-media-editor] $line';
  debugPrint(full);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    p.join(docs.path, 'srs_media_editor_probe.txt'),
  ).writeAsStringSync('$full\n', mode: FileMode.append, flush: true);
}

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 树里（含 offstage）所有 Texture 的 id 与全局矩形。
List<String> _textures(WidgetTester tester) => <String>[
  for (final Element e in find.byType(Texture, skipOffstage: false).evaluate())
    () {
      final Texture w = e.widget as Texture;
      final RenderBox? box = e.renderObject as RenderBox?;
      // 片段的 Texture 在 FittedBox 里（按原生尺寸布局再缩放）：取真实上屏矩形要带变换。
      final Rect r = box == null || !box.hasSize
          ? Rect.zero
          : MatrixUtils.transformRect(
              box.getTransformTo(null),
              Offset.zero & box.size,
            );
      return 'id=${w.textureId} filter=${w.filterQuality} rect=$r';
    }(),
];

/// 根图层整帧抓成 RGBA（与 captureFlutterFrame 同源，便于在 Dart 里比像素）。
Future<(ui.Image, ByteData)?> _grab(WidgetTester tester) async {
  final RenderView view = tester.binding.renderViews.first;
  final OffsetLayer layer = view.debugLayer! as OffsetLayer;
  final ui.Image? image = await tester.runAsync(
    () => layer.toImage(
      Offset.zero & view.size,
      pixelRatio: tester.view.devicePixelRatio,
    ),
  );
  if (image == null) return null;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return data == null ? null : (image, data);
}

/// [rect]（逻辑像素）区域的像素签名：平均亮度 + 相邻像素差（清晰度粗测：越糊越小）。
String _regionStats(ui.Image image, ByteData px, Rect rect, double dpr) {
  final int x0 = (rect.left * dpr).round().clamp(0, image.width - 1);
  final int y0 = (rect.top * dpr).round().clamp(0, image.height - 1);
  final int x1 = (rect.right * dpr).round().clamp(0, image.width);
  final int y1 = (rect.bottom * dpr).round().clamp(0, image.height);
  double luma = 0;
  double grad = 0;
  int n = 0;
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1 - 1; x++) {
      final int i = (y * image.width + x) * 4;
      final double l =
          0.299 * px.getUint8(i) +
          0.587 * px.getUint8(i + 1) +
          0.114 * px.getUint8(i + 2);
      final int j = i + 4;
      final double r =
          0.299 * px.getUint8(j) +
          0.587 * px.getUint8(j + 1) +
          0.114 * px.getUint8(j + 2);
      luma += l;
      grad += (l - r).abs();
      n++;
    }
  }
  if (n == 0) return 'empty';
  return 'px=${x1 - x0}x${y1 - y0} luma=${(luma / n).toStringAsFixed(1)} '
      'grad=${(grad / n).toStringAsFixed(2)}';
}

/// 片段画面的 Texture（释义 WebView 也是 Texture，按片段组件祖先区分）。
Finder _clipTexture([Finder? of]) => find.descendant(
  of: of ?? find.byType(SrsCardVideoClip),
  matching: find.byType(Texture),
);

/// 带变换的上屏矩形（[WidgetTester.getRect] 取两角 localToGlobal，已含缩放）。
Rect? _rectOf(WidgetTester tester, Finder f) =>
    f.evaluate().isEmpty ? null : tester.getRect(f.first);

/// 调一个带回调的控件（按 key 找，不点坐标）。
void _invoke(WidgetTester tester, Finder f) {
  final dynamic w = tester.widget(f);
  try {
    (w.onTap as VoidCallback?)!.call();
  } on NoSuchMethodError {
    (w.onPressed as VoidCallback?)!.call();
  }
}

const String _markScript =
    'window.__probeMark = (window.__probeMark || 0) + 1; '
    'JSON.stringify({mark: window.__probeMark, url: location.href.slice(0, 30)})';
const String _readMarkScript =
    'JSON.stringify({mark: window.__probeMark || 0, '
    'text: (document.body ? document.body.innerText : "").replace(/\\s+/g, " ").slice(0, 60)})';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('片段放大视图 + 跳转编辑页的预览 / 焦点 / 清晰度', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await _pumpFor(tester, const Duration(seconds: 1));

    final BuildContext rootContext = appModel.navigatorKey.currentContext!;
    final ProviderContainer container = ProviderScope.containerOf(rootContext);
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    await store.ensureBuiltins();
    final SrsMediaStore media = (await container.read(
      srsMediaStoreProvider.future,
    ))!;
    media.root.createSync(recursive: true);
    File(_clip).copySync(p.join(media.root.path, 'clip.mp4'));
    final String uid = store.profileUid;
    final Map<String, String> fields = <String, String>{
      ...srsSampleCardFields(),
      'Picture': '[sound:clip.mp4]',
      'ExpressionAudio': '',
      'SentenceAudio': '',
    };
    await store.createNote(
      noteTypeId: store.fushiCardNoteTypeId,
      createdAt: 1700000000000,
      fieldsById: <String, String>{
        for (final MapEntry<String, String> e in fields.entries)
          srsFushiCardFieldId(uid, e.key): e.value,
      },
    );
    container.read(srsRevisionProvider.notifier).state++;
    final double dpr = tester.view.devicePixelRatio;
    _log('view=${tester.view.physicalSize / dpr} dpr=$dpr');

    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              SrsReviewPage(deckId: store.defaultDeckId, deckName: 'media'),
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _pumpFor(tester, const Duration(seconds: 4));
    _log('review clips=${find.byType(SrsCardVideoClip).evaluate().length}');
    _log('review textures ${_textures(tester)}');
    await captureFlutterFrame(tester, 'media-01-review-back');
    final Rect? reviewRect = _rectOf(tester, _clipTexture());
    _log('review clip rect=$reviewRect');
    final (ui.Image, ByteData)? g1 = await _grab(tester);
    if (g1 != null && reviewRect != null) {
      _log('review clip ${_regionStats(g1.$1, g1.$2, reviewRect, dpr)}');
    }

    // ---- 1. 放大视图
    _invoke(
      tester,
      find.byKey(const ValueKey<String>('srs-card-video-expand')),
    );
    await _pumpFor(tester, const Duration(seconds: 2));
    final List<String> both = _textures(tester);
    _log('expanded textures $both');
    final Set<int> ids = <int>{
      for (final Element e
          in find.byType(Texture, skipOffstage: false).evaluate())
        (e.widget as Texture).textureId,
    };
    _log('expanded distinct texture ids=$ids count=${both.length}');
    final Finder expanded = find.byKey(
      const ValueKey<String>('srs-card-video-expanded'),
    );
    _log('expanded dialog found=${expanded.evaluate().length}');
    final Rect? bigRect = _rectOf(tester, _clipTexture(expanded));
    _log('expanded clip rect=$bigRect');
    await captureFlutterFrame(tester, 'media-02-expanded-paused');
    final (ui.Image, ByteData)? a = await _grab(tester);
    _invoke(tester, expanded); // 播放
    await _pumpFor(tester, const Duration(milliseconds: 1500));
    final (ui.Image, ByteData)? b = await _grab(tester);
    await captureFlutterFrame(tester, 'media-03-expanded-playing');
    // 宿主侧在这段停顿里做 OS 级抓屏（PrintWindow / 置顶后 CopyFromScreen），与图层截图对照。
    _log('HOLD-EXPANDED begin');
    await _pumpFor(tester, const Duration(seconds: 12));
    _log('HOLD-EXPANDED end');
    if (a != null && b != null && bigRect != null) {
      _log('expanded paused ${_regionStats(a.$1, a.$2, bigRect, dpr)}');
      _log('expanded playing ${_regionStats(b.$1, b.$2, bigRect, dpr)}');
    }
    _invoke(tester, expanded); // 暂停
    await _pumpFor(tester, const Duration(milliseconds: 300));
    _invoke(
      tester,
      find.byKey(const ValueKey<String>('srs-card-video-expanded-close')),
    );
    await _pumpFor(tester, const Duration(seconds: 2));
    _log('after close textures ${_textures(tester)}');
    await captureFlutterFrame(tester, 'media-04-after-close');
    final (ui.Image, ByteData)? c = await _grab(tester);
    final Rect? afterRect = _rectOf(tester, _clipTexture());
    if (c != null && afterRect != null) {
      _log('after close clip ${_regionStats(c.$1, c.$2, afterRect, dpr)}');
    }

    // ---- 2. 编辑页（从复习页顶栏跳转）
    final Finder edit = find.byKey(const ValueKey<String>('srs_review_edit'));
    _log('edit button found=${edit.evaluate().length}');
    _invoke(tester, edit.first);
    await _pumpFor(tester, const Duration(seconds: 4));
    _log('editor open=${find.byType(SrsNoteEditorPage).evaluate().length}');
    _log('editor textures ${_textures(tester)}');
    _log(
      'editor previewWebviews='
      '${find.byType(InAppWebView, skipOffstage: false).evaluate().length}',
    );
    await captureFlutterFrame(tester, 'media-05-editor');
    final Rect? edRect = _rectOf(tester, _clipTexture());
    _log('editor clip rect=$edRect');
    if (edRect != null) {
      final (ui.Image, ByteData)? g2 = await _grab(tester);
      if (g2 != null) {
        _log('editor clip ${_regionStats(g2.$1, g2.$2, edRect, dpr)}');
      }
    }

    // 预览里的 WebView：打页内标记，改字段后看标记是否还在（整页重载会清掉）。
    final InAppWebViewController? previewWeb = SrsWebCardFace.debugController;
    _log('preview controller=${previewWeb != null}');
    if (previewWeb != null) {
      _log('mark ${await previewWeb.evaluateJavascript(source: _markScript)}');
    }

    final Finder fieldsFinder = find.byType(EditableText);
    _log('editable fields=${fieldsFinder.evaluate().length}');
    if (fieldsFinder.evaluate().isEmpty) {
      _log('RESULT editor no editable fields');
      return;
    }
    // 找内容是「Expression 样例值」的那个输入框。
    final String expression = fields['Expression']!;
    Finder target = fieldsFinder.first;
    for (final Element e in fieldsFinder.evaluate()) {
      final EditableText w = e.widget as EditableText;
      if (w.controller.text.contains(expression)) {
        target = find.byWidget(w);
        break;
      }
    }
    final EditableText editable = tester.widget<EditableText>(target);
    editable.focusNode.requestFocus();
    await _pumpFor(tester, const Duration(milliseconds: 500));
    _log('field focused before typing=${editable.focusNode.hasFocus}');
    final InAppWebViewController? before = SrsWebCardFace.debugController;
    int lostFocus = 0;
    for (int i = 0; i < 5; i++) {
      final TextEditingValue v = editable.controller.value;
      final String next = '${v.text}あ';
      editable.controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      await _pumpFor(tester, const Duration(milliseconds: 120));
      await captureFlutterFrame(tester, 'media-06-typing-$i-mid');
      await _pumpFor(tester, const Duration(milliseconds: 500));
      final bool focused = editable.focusNode.hasFocus;
      if (!focused) lostFocus++;
      final InAppWebViewController? now = SrsWebCardFace.debugController;
      Object? mark;
      if (now != null) {
        try {
          mark = await now.evaluateJavascript(source: _readMarkScript);
        } catch (e) {
          mark = 'eval error $e';
        }
      }
      _log(
        'typing#$i focused=$focused primary=${FocusManager.instance.primaryFocus?.debugLabel} '
        'sameController=${identical(now, before)} page=$mark',
      );
    }
    await captureFlutterFrame(tester, 'media-07-editor-after-typing');
    _log('RESULT editor lostFocusCount=$lostFocus');

    // 预览切到背面（片段在背面）：与复习页同一张卡的片段比显示尺寸 / 纹理 / 像素。
    editable.focusNode.unfocus();
    final Finder preview = find.byType(SrsNotePreview);
    bool switched = false;
    for (final Element e
        in find
            .descendant(
              of: preview,
              matching: find.byWidgetPredicate((Widget w) {
                return w.runtimeType.toString().contains('Segmented');
              }),
            )
            .evaluate()) {
      try {
        ((e.widget as dynamic).onSelectionChanged as Function)(<bool>{true});
        switched = true;
        break;
      } on NoSuchMethodError {
        continue;
      }
    }
    _log('preview switched to back=$switched');
    await _pumpFor(tester, const Duration(seconds: 4));
    final Rect? backRect = _rectOf(tester, _clipTexture(preview));
    _log('editor back textures ${_textures(tester)}');
    _log('editor back clip rect=$backRect (review clip rect=$reviewRect)');
    await captureFlutterFrame(tester, 'media-08-editor-back');
    final (ui.Image, ByteData)? g3 = await _grab(tester);
    if (g3 != null && backRect != null) {
      _log('editor back clip ${_regionStats(g3.$1, g3.$2, backRect, dpr)}');
    }
    final InAppWebViewController? backWeb = SrsWebCardFace.debugController;
    if (backWeb != null) {
      _log(
        'back mark ${await backWeb.evaluateJavascript(source: _markScript)}',
      );
    }
    editable.focusNode.requestFocus();
    await _pumpFor(tester, const Duration(milliseconds: 400));
    for (int i = 0; i < 3; i++) {
      final String next = '${editable.controller.text}い';
      editable.controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      await _pumpFor(tester, const Duration(milliseconds: 120));
      await captureFlutterFrame(tester, 'media-09-back-typing-$i-mid');
      await _pumpFor(tester, const Duration(milliseconds: 500));
      Object? mark;
      final InAppWebViewController? now = SrsWebCardFace.debugController;
      if (now != null) {
        try {
          mark = await now.evaluateJavascript(source: _readMarkScript);
        } catch (e) {
          mark = 'eval error $e';
        }
      }
      _log(
        'back typing#$i focused=${editable.focusNode.hasFocus} '
        'sameController=${identical(now, backWeb)} '
        'clipRect=${_rectOf(tester, _clipTexture(preview))} page=$mark',
      );
    }
    _log('HOLD-EDITOR begin');
    await _pumpFor(tester, const Duration(seconds: 12));
    _log('HOLD-EDITOR end');
    // 不保存：返回丢弃草稿。
  }, skip: _clip.isEmpty);
}
