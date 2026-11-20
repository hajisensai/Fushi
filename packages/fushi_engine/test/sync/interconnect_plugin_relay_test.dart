import 'package:fushi_engine/sync/interconnect_plugin_relay.dart';
import 'package:test/test.dart';

const InterconnectPluginRelayMediaTarget _target =
    InterconnectPluginRelayMediaTarget(
      pluginId: 'p',
      url: 'https://cdn.example.com/a.flac',
      headers: <String, String>{'referer': 'https://example.com/'},
    );

void main() {
  test('流票：随机且不可猜、记下签发凭据、到期作废', () {
    DateTime now = DateTime.utc(2026, 11, 16);
    final InterconnectPluginRelayTickets tickets =
        InterconnectPluginRelayTickets(
          ttl: const Duration(hours: 6),
          now: () => now,
        );
    final String a = tickets.issue(_target, 'Basic abc');
    final String b = tickets.issue(_target, 'Basic abc');
    expect(a, isNot(b));
    expect(a.length, greaterThanOrEqualTo(43), reason: '32 字节 base64url');
    expect(a, isNot(contains('/')));
    expect(tickets.lookup(a)!.target.url, _target.url);
    expect(tickets.lookup(a)!.authorization, 'Basic abc');
    expect(tickets.lookup('nope'), isNull);

    now = now.add(const Duration(hours: 6));
    expect(tickets.lookup(a), isNull);
    expect(tickets.length, 0);
  });

  test('流票：超出容量作废最早签发的', () {
    final InterconnectPluginRelayTickets tickets =
        InterconnectPluginRelayTickets(capacity: 2);
    final String a = tickets.issue(_target, 'x');
    final String b = tickets.issue(_target, 'x');
    final String c = tickets.issue(_target, 'x');
    expect(tickets.lookup(a), isNull);
    expect(tickets.lookup(b), isNotNull);
    expect(tickets.lookup(c), isNotNull);
  });
}
