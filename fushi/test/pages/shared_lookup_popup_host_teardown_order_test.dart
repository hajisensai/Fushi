import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/shared_lookup_popup_host.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:material_ui/material_ui.dart';

/// 词典页 / Texthooker 的共享查词浮层宿主：attach / detach / 私有宿主 dispose 的
/// 先后顺序（BUG-5604）。
///
/// 两页都按同一范式在 initState 里登记：私有宿主（没有上层共享宿主时自建）先登记
/// `dispose`，再 `attach(this)` 并登记 `detach(this)`。撤销按登记逆序跑，所以不论
/// 正常 dispose 还是 initState 半途抛错，都是「先 detach、后 dispose」——反过来
/// 会让 detach 落在已销毁的宿主上（controller 已释放、帧后 apply 读已释放对象）。
void main() {
  group('源码范式锁定', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/home_dictionary_page.dart',
      'lib/src/pages/implementations/texthooker_page.dart',
    ]) {
      test(path, () {
        final String src = File(path).readAsStringSync();
        final int ownDispose = src.indexOf(
          'if (ownedPopupHost != null) onTeardown(ownedPopupHost.dispose);',
        );
        final int attach = src.indexOf('_popupHost.attach(this);');
        final int detach = src.indexOf(
          'onTeardown(() => _popupHost.detach(this));',
        );
        expect(ownDispose, greaterThan(0), reason: '私有宿主 dispose 未登记');
        expect(
          attach,
          greaterThan(ownDispose),
          reason: 'attach 必须在登记 dispose 之后',
        );
        expect(
          detach,
          greaterThan(attach),
          reason: 'detach 必须紧跟 attach 登记（逆序撤销时先于宿主 dispose）',
        );
        // dispose 里不再手写 detach / 宿主 dispose，统一走清单。
        expect(src.contains('_popupHost.detach(this);\n'), isFalse);
        expect(src.contains('_ownedPopupHost?.dispose();'), isFalse);
        expect(src.contains('releaseResources();'), isTrue);
      });
    }
  });

  group('同一范式的行为', () {
    testWidgets('正常 dispose：先 detach 再销毁私有宿主', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(_Owner(log: log, throwAfterAttach: false));
      expect(log, <String>['attach']);
      await tester.pumpWidget(const SizedBox());
      expect(log, <String>['attach', 'detach', 'dispose']);
    });

    testWidgets('initState 在 attach 之后抛错：同样先 detach 再销毁，不漏', (
      WidgetTester tester,
    ) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(_Owner(log: log, throwAfterAttach: true));
      expect(tester.takeException(), isA<StateError>());
      await tester.pump();
      expect(log, <String>['attach', 'detach', 'dispose']);
    });

    testWidgets('共享宿主：挂载失败后注销自己，宿主不被销毁', (WidgetTester tester) async {
      final List<String> log = <String>[];
      final _RecordingHost shared = _RecordingHost(log);
      await tester.pumpWidget(
        _Owner(log: log, throwAfterAttach: true, shared: shared),
      );
      expect(tester.takeException(), isA<StateError>());
      await tester.pump();
      expect(log, <String>['attach', 'detach']);
      expect(shared.debugOwnerCount, 0);
      shared.dispose();
    });
  });
}

class _RecordingHost extends SharedLookupPopupHost {
  _RecordingHost(this.log);

  final List<String> log;

  @override
  void attach(SharedLookupPopupOwner owner) {
    log.add('attach');
    super.attach(owner);
  }

  @override
  void detach(SharedLookupPopupOwner owner) {
    log.add('detach');
    super.detach(owner);
  }

  @override
  void dispose() {
    log.add('dispose');
    super.dispose();
  }
}

class _Owner extends StatefulWidget {
  const _Owner({
    required this.log,
    required this.throwAfterAttach,
    this.shared,
  });

  final List<String> log;
  final bool throwAfterAttach;
  final SharedLookupPopupHost? shared;

  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner>
    with StateResourceScope<_Owner>
    implements SharedLookupPopupOwner {
  SharedLookupPopupHost? _ownedPopupHost;
  late final SharedLookupPopupHost _popupHost;

  @override
  void initState() {
    super.initState();
    final SharedLookupPopupHost? shared = widget.shared;
    if (shared == null) _ownedPopupHost = _RecordingHost(widget.log);
    _popupHost = shared ?? _ownedPopupHost!;
    final SharedLookupPopupHost? ownedPopupHost = _ownedPopupHost;
    if (ownedPopupHost != null) onTeardown(ownedPopupHost.dispose);
    _popupHost.attach(this);
    onTeardown(() => _popupHost.detach(this));
    if (widget.throwAfterAttach) throw StateError('initState failed');
  }

  @override
  void dispose() {
    releaseResources();
    super.dispose();
  }

  @override
  List<Widget> buildSharedLookupPopupLayers(
    BuildContext context,
    Size screen,
  ) => const <Widget>[];

  @override
  ThemeData? get sharedLookupPopupTheme => null;

  @override
  bool get sharedLookupPopupOwnerAlive => mounted;

  @override
  void onSharedLookupPopupClaimed(DictionaryPopupController controller) {}

  @override
  Widget build(BuildContext context) => const SizedBox();
}
