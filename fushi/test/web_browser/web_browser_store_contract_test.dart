import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/data/drift_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi_core/fushi_core.dart';

import 'web_browser_store_contract.dart';

/// 同一套 [WebBrowserStore] 契约跑在内存版与 Drift 版上。
void main() {
  // 每个用例各开一个独立的内存库（契约要求隔离），不是同一执行器的重复实例。
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  defineWebBrowserStoreContract(
    'MemoryWebBrowserStore',
    create: (DateTime Function() clock) => MemoryWebBrowserStore(clock: clock),
  );

  final Map<WebBrowserStore, FushiDatabase> dbs =
      <WebBrowserStore, FushiDatabase>{};
  defineWebBrowserStoreContract(
    'DriftWebBrowserStore',
    create: (DateTime Function() clock) {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final DriftWebBrowserStore store = DriftWebBrowserStore(db, clock: clock);
      dbs[store] = db;
      return store;
    },
    dispose: (WebBrowserStore store) async {
      (store as DriftWebBrowserStore).dispose();
      await dbs.remove(store)!.close();
    },
  );
}
