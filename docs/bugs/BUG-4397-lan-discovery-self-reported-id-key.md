## BUG-4397 · 局域网发现以对端自报 id 为键被冒名覆盖，mDNS 回退缓存收录无关记录且不回收
- **报告**：2026-11-10（用户：互联审查 C10）
- **真实性**：✅ 真 bug。
  - `fushi/lib/src/sync/lan_discovery_service.dart:302-305`（基准 94317ab6295）：`_discoveredDevices[device.deviceId] = device`，主键是对端自报、未经认证的 TXT `id`；局域网里任一设备广播同一 id，后到的条目覆盖先到的（冒名顶掉真设备）。lost 分支 `:311-314` 还会在服务名未登记时回落按 TXT id 删除，同样可被冒名。
  - `fushi/lib/src/sync/mdns_fallback.dart:752-773`：只有 PTR 按 `_serviceName` 过滤，SRV / TXT / A 不分来源全部进缓存（打印机、AirPlay 等无关服务）。
  - `fushi/lib/src/sync/mdns_fallback.dart:789-791` 与 `:769-770`：`debugSweep` 与 ttl=0 只删 `_a` 内层地址，外层主机名键永不回收。
- **[x] ① 已修复** — `2ed3ded77e6`：发现表改以 `host:port` 端点作键（一个端点只能有一个服务监听），`_serviceNameToDeviceId` 改为 `_serviceNameToEndpoint`；同名服务换端点删旧项，同端点换实例名清掉旧名映射（旧名迟到的 lost 不删活项）；lost 只按登记过的服务名删，不再信 TXT id。mDNS 回退：SRV / TXT 只收 `<instance>.<本服务>`，A 只收某条已缓存 SRV 的 target（两遍处理同包记录），ttl=0 与 sweep 回收空的 / 无 SRV 指向的主机名。
- **[x] ② 已加自动化测试** — `fushi/test/sync/lan_discovery_service_test.dart`（组「C10 TXT id impersonation」三条 + 「lost event of an unknown name carrying a known id is a no-op」）、`fushi/test/sync/mdns_fallback_test.dart`（「records of other services and their hosts are never cached」「an expired host name is reclaimed…」「an A goodbye that empties a host name drops the name」）；修复前 6 条红，修复后两文件 39 条全绿。
- **备注**：旧测试「lost event with TXT id attribute keeps working」钉的正是按 TXT id 回落删除的冒名入口，已改写为相反契约。先于 SRV 到达的 A 记录会被丢弃，由 `_reconcile` 对缺地址的 SRV target 发 follow-up A 查询补回（现有逻辑）。外部 PR #3094 改同一 resolved 分支：其 `_evictSupersededBy` 在端点键下不再需要，`_withKnownTxtFacts` 与本修复正交。
