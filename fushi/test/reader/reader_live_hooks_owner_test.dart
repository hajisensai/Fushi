import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';

// BUG-3001：阅读器实时 hook（按钮布局 / 反转底栏 / 样式 / 排版热更新）是
// ReaderFushiSource 上的静态回调。旧实现每个阅读器页 dispose 时无条件置 null；
// 切卷走 pushReplacement，新页 initState 先登记、旧页转场结束才 dispose，于是
// 仍在显示的新阅读器的 hook 被抹掉——之后在书内设置里改按钮位置，偏好写进去了
// 阅读器却不重建，退出重进才生效。现在按持有者栈登记 / 注销，hook 恒指向栈顶。
void main() {
  final List<String> calls = <String>[];

  ReaderLiveHooks hooksOf(String owner) => ReaderLiveHooks(
    settingsChanged: () => calls.add('$owner.settings'),
    layoutReload: () => calls.add('$owner.layout'),
    chromeReload: () => calls.add('$owner.chrome'),
    chromeReanchor: () => calls.add('$owner.reanchor'),
  );

  void fireAll() {
    ReaderFushiSource.onSettingsChangedLive?.call();
    ReaderFushiSource.onLayoutReloadLive?.call();
    ReaderFushiSource.onChromeReloadLive?.call();
    ReaderFushiSource.onChromeReanchorLive?.call();
  }

  setUp(calls.clear);

  tearDown(() {
    expect(
      ReaderFushiSource.debugLiveHookOwnerCount,
      0,
      reason: '每个用例都应注销干净，否则静态 hook 泄漏到别的用例',
    );
  });

  test('切卷：新页先登记、旧页后注销，hook 仍指向新页', () {
    final ReaderLiveHooks oldPage = hooksOf('old');
    final ReaderLiveHooks newPage = hooksOf('new');
    ReaderFushiSource.attachLiveHooks(oldPage);
    ReaderFushiSource.attachLiveHooks(newPage);
    ReaderFushiSource.detachLiveHooks(oldPage);

    fireAll();
    expect(calls, <String>[
      'new.settings',
      'new.layout',
      'new.chrome',
      'new.reanchor',
    ]);

    ReaderFushiSource.detachLiveHooks(newPage);
    expect(ReaderFushiSource.onChromeReanchorLive, isNull);
    expect(ReaderFushiSource.onChromeReloadLive, isNull);
    expect(ReaderFushiSource.onSettingsChangedLive, isNull);
    expect(ReaderFushiSource.onLayoutReloadLive, isNull);
  });

  test('叠开阅读器：上层关闭后 hook 回落到下层阅读器', () {
    final ReaderLiveHooks lower = hooksOf('lower');
    final ReaderLiveHooks upper = hooksOf('upper');
    ReaderFushiSource.attachLiveHooks(lower);
    ReaderFushiSource.attachLiveHooks(upper);

    ReaderFushiSource.onChromeReanchorLive?.call();
    ReaderFushiSource.detachLiveHooks(upper);
    ReaderFushiSource.onChromeReanchorLive?.call();
    expect(calls, <String>['upper.reanchor', 'lower.reanchor']);

    ReaderFushiSource.detachLiveHooks(lower);
    expect(ReaderFushiSource.onChromeReanchorLive, isNull);
  });

  test('单个阅读器：注销后四个 hook 都置空', () {
    final ReaderLiveHooks only = hooksOf('only');
    ReaderFushiSource.attachLiveHooks(only);
    fireAll();
    expect(calls, hasLength(4));
    ReaderFushiSource.detachLiveHooks(only);
    calls.clear();
    fireAll();
    expect(calls, isEmpty);
  });

  test('重复注销同一组是无害的', () {
    final ReaderLiveHooks a = hooksOf('a');
    final ReaderLiveHooks b = hooksOf('b');
    ReaderFushiSource.attachLiveHooks(a);
    ReaderFushiSource.attachLiveHooks(b);
    ReaderFushiSource.detachLiveHooks(a);
    ReaderFushiSource.detachLiveHooks(a);
    ReaderFushiSource.onChromeReloadLive?.call();
    expect(calls, <String>['b.chrome']);
    ReaderFushiSource.detachLiveHooks(b);
  });
}
