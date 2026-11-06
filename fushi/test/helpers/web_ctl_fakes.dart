import 'package:fushi_web_core/fushi_web_core.dart';

import 'package:fushi/src/ops/ctl_web_routes.dart';

/// 广告拦截命令面的假件：状态即快照（白名单按 Rust 同口径的简化解析拆主机名），
/// 不碰原生库、不联网。
class FakeWebAdblock implements WebAdblockCtlPort {
  FakeWebAdblock({this.opened = true});

  /// false = 数据目录未就绪（快照是 [AdblockSnapshot.notOpened]）。
  bool opened;
  bool enabled = true;
  String allowlist = '';
  final Map<String, bool> subscribed = <String, bool>{
    'easylist': true,
    'easyprivacy': false,
  };
  int updates = 0;
  bool updateOk = true;

  @override
  List<AdblockCatalogEntry> get catalog => <AdblockCatalogEntry>[
    for (final String id in subscribed.keys)
      AdblockCatalogEntry(
        id: id,
        title: id,
        url: 'https://example.com/$id.txt',
        host: 'example.com',
        defaultEnabled: id == 'easylist',
      ),
  ];

  static List<String> parseHosts(String raw) {
    final List<String> out = <String>[];
    for (final String token in raw.split(RegExp(r'[\s,;，、]+'))) {
      String t = token.trim().toLowerCase();
      final int scheme = t.indexOf('://');
      if (scheme >= 0) t = t.substring(scheme + 3);
      for (final String stop in <String>['/', ':']) {
        final int i = t.indexOf(stop);
        if (i >= 0) t = t.substring(0, i);
      }
      while (t.startsWith('*.') || t.startsWith('.')) {
        t = t.substring(t.startsWith('*.') ? 2 : 1);
      }
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  @override
  AdblockSnapshot get snapshot => !opened
      ? AdblockSnapshot.notOpened
      : AdblockSnapshot(
          enabled: enabled,
          allowlist: allowlist,
          allowlistHosts: parseHosts(allowlist),
          status: AdblockEngineStatus.ready,
          syncing: false,
          ruleCount: 100,
          fromCache: false,
          lists: <AdblockListState>[
            for (final MapEntry<String, bool> e in subscribed.entries)
              AdblockListState(
                id: e.key,
                title: e.key,
                host: 'example.com',
                enabled: e.value,
                cached: true,
                stale: false,
                ruleCount: e.value ? 100 : 0,
                byteLength: 0,
              ),
          ],
          lastSyncOk: updates > 0 ? updateOk : null,
        );

  @override
  Future<void> setEnabled(bool value) async => enabled = value;

  @override
  Future<void> setListEnabled(String id, bool value) async =>
      subscribed[id] = value;

  @override
  void setAllowlist(String raw) => allowlist = raw.trim();

  @override
  Future<bool> updateNow() async {
    updates++;
    return updateOk;
  }
}
