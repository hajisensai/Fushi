import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回归护栏：**别把「别人持有的 ChangeNotifier」从 ChangeNotifierProvider 里返回。**
///
/// `ChangeNotifierProvider` 会给它 create 出来的 notifier 注册
/// `onDispose(notifier.dispose)`。只要 provider 因依赖变化而重算，上一个返回值就被
/// dispose——如果那个实例是 AppModel 之类的长生命周期对象持有并复用的，它就被就地
/// 打死，而持有方毫不知情、继续把这个死实例发给所有人。
///
/// 而 `appProvider` 是 `ChangeNotifierProvider<AppModel>`，riverpod 对 ChangeNotifier
/// 恒判 `updateShouldNotify = true`，所以**每一次** `AppModel.notifyListeners()` 都会
/// 让 `ref.watch(appProvider)` 的下游 provider 重算。两者相乘 = 服务在第一次全局状态
/// 变化时就永久失效（`VideoSpecsService` 一旦 `_disposed` 就不再探测任何文件）。
///
/// 本测试把这个机制本身钉住，不依赖 AppModel。修法见 `videoSpecsProvider`：用普通
/// `Provider` 交出实例，消费方用 `ListenableBuilder` 订阅。
void main() {
  test('ChangeNotifierProvider 重算会 dispose 上一次返回的 notifier', () {
    final _Owner owner = _Owner();
    final ChangeNotifierProvider<_Source> source =
        ChangeNotifierProvider<_Source>((Ref ref) => _Source());
    // 反面教材：把 owner 持有的实例从 ChangeNotifierProvider 里交出去。
    final ChangeNotifierProvider<_Owned> bad =
        ChangeNotifierProvider<_Owned>((Ref ref) {
      ref.watch(source);
      return owner.owned;
    });

    // 刻意不 addTearDown(container.dispose)：容器里存着已被 dispose 的实例，
    // 容器销毁时会二次 dispose 再抛一次，与本测试要证明的事无关。
    final ProviderContainer container = ProviderContainer();

    expect(container.read(bad).disposed, isFalse);

    // 模拟 AppModel.notifyListeners()。
    container.read(source).bump();
    // 重算的顺序是「先 dispose 上一次的返回值，再 create」，而 create 拿回的是
    // owner 缓存的同一个（已死的）实例，于是 addListener 当场抛断言。静默失效与
    // 直接抛两种后果都是致命的，这里只需证明它确实被 dispose 了。
    try {
      container.read(bad);
    } catch (_) {
      // 见上：debug 断言，吞掉。
    }

    expect(
      owner.owned.disposed,
      isTrue,
      reason: 'provider 重算把 owner 还在用的实例 dispose 了——'
          '这正是 videoSpecsProvider 不能用 ChangeNotifierProvider 的原因',
    );
  });

  test('普通 Provider 交出实例时不会 dispose 它', () {
    final _Owner owner = _Owner();
    final ChangeNotifierProvider<_Source> source =
        ChangeNotifierProvider<_Source>((Ref ref) => _Source());
    // 正确做法：Provider 只负责交出实例，生命周期仍归 owner。
    final Provider<_Owned> good = Provider<_Owned>((Ref ref) {
      ref.watch(source);
      return owner.owned;
    });

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(good).disposed, isFalse);

    container.read(source).bump();
    container.read(good);

    expect(owner.owned.disposed, isFalse,
        reason: 'Provider 不接管返回值的生命周期');
    // 仍然是同一个实例，消费方可以安全地 ListenableBuilder 订阅它。
    expect(identical(container.read(good), owner.owned), isTrue);
  });
}

class _Owner {
  final _Owned owned = _Owned();
}

class _Owned extends ChangeNotifier {
  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _Source extends ChangeNotifier {
  void bump() => notifyListeners();
}
