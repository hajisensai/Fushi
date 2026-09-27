import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/sync/game_stream_host.dart';

List<StatsReport> _reports({
  required int framesSent,
  required int framesEncoded,
  required double totalEncodeTime,
  required int bytesSent,
  required int audioPackets,
}) => <StatsReport>[
  StatsReport('v', 'outbound-rtp', 0, <dynamic, dynamic>{
    'kind': 'video',
    'framesSent': framesSent,
    'framesEncoded': framesEncoded,
    'totalEncodeTime': totalEncodeTime,
    'bytesSent': bytesSent,
    'frameWidth': 1920,
    'frameHeight': 1080,
    'qualityLimitationReason': 'cpu',
    'encoderImplementation': 'libvpx',
    'retransmittedBytesSent': 0,
  }),
  StatsReport('a', 'outbound-rtp', 0, <dynamic, dynamic>{
    'kind': 'audio',
    'packetsSent': audioPackets,
  }),
  StatsReport('p', 'candidate-pair', 0, <dynamic, dynamic>{
    'nominated': true,
    'currentRoundTripTime': 0.004,
    'availableOutgoingBitrate': 30000000,
  }),
];

void main() {
  group('bandwidth estimate', () {
    StatsReport pair(String id, Map<String, Object?> values) =>
        StatsReport(id, 'candidate-pair', 0, <dynamic, dynamic>{
          'nominated': true,
          'state': 'succeeded',
          'currentRoundTripTime': 0.003,
          ...values,
        });

    test('comes from the transport\'s selected candidate pair', () {
      final GameStreamSenderStats stats = GameStreamSenderStats.fromReports(
        <StatsReport>[
          pair('CPv4', <String, Object?>{'availableOutgoingBitrate': 8000000}),
          // Another nominated pair (IPv6 / second interface) listed later,
          // without an estimate: it must not shadow the selected one.
          pair('CPv6', <String, Object?>{'currentRoundTripTime': 0.009}),
          StatsReport('T', 'transport', 0, <dynamic, dynamic>{
            'selectedCandidatePairId': 'CPv4',
          }),
        ],
        at: DateTime(2026, 9, 27),
      );
      expect(stats.availableOutgoingKbps, 8000);
      expect(stats.rttMs, 3);
    });

    test('falls back to the pair that carries an estimate', () {
      final GameStreamSenderStats stats = GameStreamSenderStats.fromReports(
        <StatsReport>[
          pair('A', <String, Object?>{'availableOutgoingBitrate': 6000000}),
          pair('B', <String, Object?>{}),
        ],
        at: DateTime(2026, 9, 27),
      );
      expect(stats.availableOutgoingKbps, 6000);
    });
  });

  test('sender stats line reports rates over the sampling window', () {
    final DateTime t0 = DateTime(2026, 9, 26, 12);
    final GameStreamSenderStats first = GameStreamSenderStats.fromReports(
      _reports(
        framesSent: 100,
        framesEncoded: 100,
        totalEncodeTime: 1.0,
        bytesSent: 1000000,
        audioPackets: 50,
      ),
      at: t0,
    );
    final GameStreamSenderStats second = GameStreamSenderStats.fromReports(
      _reports(
        framesSent: 160,
        framesEncoded: 160,
        totalEncodeTime: 1.6,
        bytesSent: 3500000,
        audioPackets: 150,
      ),
      at: t0.add(const Duration(seconds: 2)),
    );

    final String line = second.describe(since: first);

    expect(line, contains('size=1920x1080'));
    expect(line, contains('sent=30.0fps'));
    expect(line, contains('encode=10.00ms'));
    expect(line, contains('limit=cpu encoder=libvpx'));
    expect(line, contains('kbps=10000'));
    expect(line, contains('avail=30000'));
    expect(line, contains('rtt=4ms'));
    expect(line, contains('audio=50.0pps'));
  });

  test('first sample has no rates yet', () {
    final GameStreamSenderStats only = GameStreamSenderStats.fromReports(
      _reports(
        framesSent: 1,
        framesEncoded: 1,
        totalEncodeTime: 0,
        bytesSent: 1,
        audioPackets: 1,
      ),
      at: DateTime(2026),
    );
    expect(only.describe(), contains('sent=-fps'));
    expect(only.describe(), contains('audio=-pps'));
  });
}
