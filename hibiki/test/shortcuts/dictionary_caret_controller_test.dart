import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/shortcuts/dictionary_caret_controller.dart';

/// Recording fake host: lets us assert which host seams the controller drives
/// without a real WebView / popup. The popup-touching transitions early-return
/// on the branches exercised here (no popup → none, not-mounted, surface==none),
/// so a null [caretTopPopupState] is enough — the JS-driven happy path is
/// covered by device integration tests (same split the source-scan guards use).
class _FakeCaretHost implements DictionaryCaretHost {
  _FakeCaretHost({this.mounted = true, this.topPopup, this.topIndex = -1});

  bool mounted;
  DictionaryPopupWebViewState? topPopup;
  int topIndex;

  int setStateCount = 0;
  int exitPrimaryRingCount = 0;

  @override
  bool get caretHostMounted => mounted;

  @override
  DictionaryPopupWebViewState? get caretTopPopupState => topPopup;

  @override
  int get caretTopVisiblePopupIndex => topIndex;

  @override
  void caretSetState(VoidCallback fn) {
    setStateCount++;
    fn();
  }

  @override
  void caretExitPrimaryRing() => exitPrimaryRingCount++;
}

void main() {
  group('DictionaryCaretController state machine', () {
    test('starts inactive on the none surface', () {
      final c = DictionaryCaretController(_FakeCaretHost());
      expect(c.surface, CaretSurface.none);
      expect(c.active, isFalse);
      expect(c.onReader, isFalse);
      expect(c.onLyrics, isFalse);
      expect(c.onPopup, isFalse);
      expect(c.popupState, isNull);
      expect(c.busy, isFalse);
    });

    test('derived getters track the surface field', () {
      final c = DictionaryCaretController(_FakeCaretHost());

      c.surface = CaretSurface.reader;
      expect(c.active, isTrue);
      expect(c.onReader, isTrue);
      expect(c.onLyrics, isFalse);
      expect(c.onPopup, isFalse);

      c.surface = CaretSurface.lyrics;
      expect(c.onLyrics, isTrue);
      expect(c.onReader, isFalse);

      c.surface = CaretSurface.popup;
      expect(c.onPopup, isTrue);
      expect(c.active, isTrue);
    });

    test('setSurface routes the change through the host rebuild', () {
      final host = _FakeCaretHost();
      final c = DictionaryCaretController(host);

      c.setSurface(CaretSurface.reader);
      expect(c.surface, CaretSurface.reader);
      expect(host.setStateCount, 1);
    });

    test('resetWithState clears surface + popup through the host rebuild', () {
      final host = _FakeCaretHost();
      final c = DictionaryCaretController(host)..surface = CaretSurface.popup;

      c.resetWithState();
      expect(c.surface, CaretSurface.none);
      expect(c.popupState, isNull);
      expect(host.setStateCount, 1);
    });
  });

  group('DictionaryCaretController.resumePopupCaretForHardwareNav', () {
    test('drops to none when the top popup is gone', () {
      final host = _FakeCaretHost(topPopup: null);
      final c = DictionaryCaretController(host)..surface = CaretSurface.popup;

      c.resumePopupCaretForHardwareNav();

      expect(c.surface, CaretSurface.none);
      expect(c.popupState, isNull);
      // Pure reset (no popup) takes no host rebuild and no ring exit.
      expect(host.setStateCount, 0);
      expect(host.exitPrimaryRingCount, 0);
    });
  });

  group('DictionaryCaretController.onDictionaryStackChanged', () {
    test('is a no-op when the cursor is not on a popup', () {
      final host = _FakeCaretHost();
      final c = DictionaryCaretController(host)..surface = CaretSurface.reader;

      c.onDictionaryStackChanged();

      expect(host.setStateCount, 0);
      expect(c.surface, CaretSurface.reader);
    });

    test('is a no-op when the host is unmounted', () {
      final host = _FakeCaretHost(mounted: false);
      final c = DictionaryCaretController(host)..surface = CaretSurface.popup;

      c.onDictionaryStackChanged();

      expect(host.setStateCount, 0);
    });
  });

  group('DictionaryCaretController.onDictionaryPopupRendered', () {
    test('is a no-op for pure-touch users (surface == none)', () {
      final host = _FakeCaretHost(topIndex: 0);
      final c = DictionaryCaretController(host); // surface stays none

      c.onDictionaryPopupRendered(0);

      expect(host.setStateCount, 0);
      expect(c.surface, CaretSurface.none);
    });

    test('ignores a render of a non-top popup index', () {
      final host = _FakeCaretHost(topIndex: 1);
      final c = DictionaryCaretController(host)..surface = CaretSurface.popup;

      c.onDictionaryPopupRendered(0); // index != topVisiblePopupIndex

      expect(host.setStateCount, 0);
    });
  });
}
