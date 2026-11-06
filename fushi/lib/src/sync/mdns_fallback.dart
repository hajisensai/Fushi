import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Minimal DNS-SD over multicast DNS (RFC 6762 / 6763) for Linux machines
/// without a running Avahi daemon (SteamOS ships Avahi disabled, WSL and
/// minimal installs have none). On Linux bonsoir only talks to Avahi over
/// D-Bus, so without this LAN discovery and advertising both fail there.
///
/// Speaks the standard wire format on 224.0.0.251:5353, so Bonjour (Apple /
/// Windows), Android NSD and Avahi peers interoperate with it. Deliberately
/// small: one service type, IPv4 only (FushiSyncServer binds IPv4), no name
/// probing / conflict resolution and no known-answer suppression.
///
/// Compatibility layer for an external limit (BUG-4119): only reached on Linux
/// after bonsoir's Avahi initialise fails (`mdnsFallbackEnabled`), never on the
/// other platforms. Remove it once LAN discovery moves into the Rust core with
/// its own mDNS stack, or once bonsoir_linux works without Avahi.

const int _typeA = 1;
const int _typePtr = 12;
const int _typeTxt = 16;
const int _typeSrv = 33;
const int _typeAny = 255;
const int _classIn = 1;
const int _cacheFlushBit = 0x8000;

/// A DNS name as labels. Compared case-insensitively, as DNS requires; kept
/// as labels because a DNS-SD instance label may itself contain dots.
@immutable
class MdnsName {
  MdnsName(List<String> labels) : labels = List<String>.unmodifiable(labels);

  /// Parses a dotted name whose labels contain no dots (service types, hosts).
  factory MdnsName.parse(String dotted) =>
      MdnsName(dotted.split('.').where((String l) => l.isNotEmpty).toList());

  final List<String> labels;

  MdnsName child(String label) => MdnsName(<String>[label, ...labels]);

  String get _key => labels.map((String l) => l.toLowerCase()).join('\u0000');

  @override
  bool operator ==(Object other) => other is MdnsName && other._key == _key;

  @override
  int get hashCode => _key.hashCode;

  @override
  String toString() => labels.join('.');
}

sealed class MdnsRecord {
  const MdnsRecord(this.name, this.ttl);
  final MdnsName name;

  /// Seconds. 0 is a "goodbye": the record is withdrawn.
  final int ttl;
}

final class MdnsPtrRecord extends MdnsRecord {
  const MdnsPtrRecord(super.name, super.ttl, this.target);
  final MdnsName target;
}

final class MdnsSrvRecord extends MdnsRecord {
  const MdnsSrvRecord(
    super.name,
    super.ttl, {
    required this.port,
    required this.target,
  });
  final int port;
  final MdnsName target;
}

final class MdnsTxtRecord extends MdnsRecord {
  const MdnsTxtRecord(super.name, super.ttl, this.attributes);
  final Map<String, String> attributes;
}

final class MdnsARecord extends MdnsRecord {
  const MdnsARecord(super.name, super.ttl, this.address);
  final InternetAddress address;
}

@immutable
class MdnsQuestion {
  const MdnsQuestion(this.name, this.type);
  final MdnsName name;
  final int type;
}

class MdnsMessage {
  MdnsMessage({
    this.id = 0,
    required this.isResponse,
    this.questions = const <MdnsQuestion>[],
    this.answers = const <MdnsRecord>[],
    this.additionals = const <MdnsRecord>[],
  });

  final int id;
  final bool isResponse;
  final List<MdnsQuestion> questions;
  final List<MdnsRecord> answers;
  final List<MdnsRecord> additionals;

  /// Answers and additionals together: browsers cache both alike.
  Iterable<MdnsRecord> get allRecords => <MdnsRecord>[
    ...answers,
    ...additionals,
  ];
}

// ── Wire format ─────────────────────────────────────────────────────────

/// Encodes [message] without name compression (valid DNS, just larger).
Uint8List encodeMdnsMessage(MdnsMessage message) {
  final BytesBuilder out = BytesBuilder(copy: false);
  void u16(int v) => out.add(<int>[(v >> 8) & 0xff, v & 0xff]);
  void u32(int v) => out.add(<int>[
    (v >> 24) & 0xff,
    (v >> 16) & 0xff,
    (v >> 8) & 0xff,
    v & 0xff,
  ]);
  void name(MdnsName n, BytesBuilder to) {
    for (final String label in n.labels) {
      final List<int> bytes = _truncateUtf8(label, 63);
      to.addByte(bytes.length);
      to.add(bytes);
    }
    to.addByte(0);
  }

  u16(message.id);
  u16(message.isResponse ? 0x8400 : 0); // QR + AA for responses
  u16(message.questions.length);
  u16(message.answers.length);
  u16(0);
  u16(message.additionals.length);
  for (final MdnsQuestion q in message.questions) {
    name(q.name, out);
    u16(q.type);
    u16(_classIn);
  }
  for (final MdnsRecord r in message.allRecords) {
    name(r.name, out);
    final BytesBuilder rdata = BytesBuilder(copy: false);
    final int type;
    bool unique = true;
    switch (r) {
      case MdnsPtrRecord():
        type = _typePtr;
        unique = false; // shared: many hosts answer the same service PTR
        name(r.target, rdata);
      case MdnsSrvRecord():
        type = _typeSrv;
        rdata.add(<int>[0, 0, 0, 0, (r.port >> 8) & 0xff, r.port & 0xff]);
        name(r.target, rdata);
      case MdnsTxtRecord():
        type = _typeTxt;
        if (r.attributes.isEmpty) rdata.addByte(0);
        r.attributes.forEach((String k, String v) {
          final List<int> entry = _truncateUtf8('$k=$v', 255);
          rdata.addByte(entry.length);
          rdata.add(entry);
        });
      case MdnsARecord():
        type = _typeA;
        rdata.add(r.address.rawAddress);
    }
    u16(type);
    u16(_classIn | (unique ? _cacheFlushBit : 0));
    u32(r.ttl);
    final Uint8List bytes = rdata.takeBytes();
    u16(bytes.length);
    out.add(bytes);
  }
  return out.takeBytes();
}

/// Decodes a received packet; null when it is malformed. Record types other
/// than A / PTR / SRV / TXT are skipped.
MdnsMessage? decodeMdnsMessage(Uint8List data) {
  try {
    return _MdnsReader(data).readMessage();
  } on FormatException {
    // Anything on the LAN can send to 5353: a malformed packet is input, not a bug.
    return null;
  }
}

List<int> _truncateUtf8(String s, int maxBytes) {
  List<int> bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return bytes;
  int end = maxBytes;
  while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
    end--; // never cut inside a multi-byte character
  }
  bytes = bytes.sublist(0, end);
  return bytes;
}

class _MdnsReader {
  _MdnsReader(this._data);
  final Uint8List _data;
  int _pos = 0;

  int _u8() {
    if (_pos >= _data.length) throw const FormatException('truncated');
    return _data[_pos++];
  }

  int _u16() => (_u8() << 8) | _u8();
  int _u32() => (_u16() << 16) | _u16();

  MdnsName _name() {
    final List<String> labels = <String>[];
    int pos = _pos;
    int? resumeAt;
    int jumps = 0;
    while (true) {
      if (pos >= _data.length) throw const FormatException('name past end');
      final int len = _data[pos];
      if (len == 0) {
        pos++;
        break;
      }
      if ((len & 0xc0) == 0xc0) {
        if (pos + 1 >= _data.length || ++jumps > 64) {
          throw const FormatException('bad name pointer');
        }
        resumeAt ??= pos + 2;
        pos = ((len & 0x3f) << 8) | _data[pos + 1];
        continue;
      }
      if ((len & 0xc0) != 0 || pos + 1 + len > _data.length) {
        throw const FormatException('bad label');
      }
      labels.add(
        utf8.decode(
          _data.sublist(pos + 1, pos + 1 + len),
          allowMalformed: true,
        ),
      );
      pos += 1 + len;
    }
    _pos = resumeAt ?? pos;
    return MdnsName(labels);
  }

  MdnsMessage readMessage() {
    final int id = _u16();
    final int flags = _u16();
    final int qd = _u16(), an = _u16(), ns = _u16(), ar = _u16();
    final List<MdnsQuestion> questions = <MdnsQuestion>[
      for (int i = 0; i < qd; i++) _question(),
    ];
    final List<MdnsRecord> answers = <MdnsRecord>[];
    final List<MdnsRecord> additionals = <MdnsRecord>[];
    for (int i = 0; i < an + ns + ar; i++) {
      final MdnsRecord? r = _record();
      if (r != null) (i < an ? answers : additionals).add(r);
    }
    return MdnsMessage(
      id: id,
      isResponse: flags & 0x8000 != 0,
      questions: questions,
      answers: answers,
      additionals: additionals,
    );
  }

  MdnsQuestion _question() {
    final MdnsName name = _name();
    final int type = _u16();
    _u16(); // class (+ QU bit)
    return MdnsQuestion(name, type);
  }

  MdnsRecord? _record() {
    final MdnsName name = _name();
    final int type = _u16();
    final int cls = _u16() & ~_cacheFlushBit;
    final int ttl = _u32();
    final int len = _u16();
    final int end = _pos + len;
    if (end > _data.length) throw const FormatException('rdata past end');
    MdnsRecord? record;
    if (cls == _classIn) {
      switch (type) {
        case _typePtr:
          record = MdnsPtrRecord(name, ttl, _name());
        case _typeSrv:
          _u16(); // priority
          _u16(); // weight
          final int port = _u16();
          record = MdnsSrvRecord(name, ttl, port: port, target: _name());
        case _typeTxt:
          final Map<String, String> attrs = <String, String>{};
          while (_pos < end) {
            final int n = _u8();
            if (_pos + n > end) throw const FormatException('bad txt');
            final String entry = utf8.decode(
              _data.sublist(_pos, _pos + n),
              allowMalformed: true,
            );
            _pos += n;
            if (entry.isEmpty) continue;
            final int eq = entry.indexOf('=');
            if (eq < 0) {
              attrs[entry] = '';
            } else if (eq > 0) {
              attrs[entry.substring(0, eq)] = entry.substring(eq + 1);
            }
          }
          record = MdnsTxtRecord(name, ttl, attrs);
        case _typeA:
          if (len == 4) {
            record = MdnsARecord(
              name,
              ttl,
              InternetAddress.fromRawAddress(_data.sublist(_pos, end)),
            );
          }
      }
    }
    _pos = end;
    return record;
  }
}

// ── Transport ───────────────────────────────────────────────────────────

class MdnsDatagram {
  const MdnsDatagram(this.data, this.address, this.port);
  final Uint8List data;
  final InternetAddress address;
  final int port;
}

/// The socket seam: real UDP in the app, in-memory in tests.
abstract interface class MdnsTransport {
  Stream<MdnsDatagram> get datagrams;

  /// Sends to the mDNS multicast group.
  void sendMulticast(Uint8List data);

  /// Sends a unicast reply (legacy queriers that do not use port 5353).
  void sendTo(Uint8List data, InternetAddress address, int port);

  /// This host's non-loopback IPv4 addresses, for A records.
  Future<List<InternetAddress>> localAddresses();

  void close();
}

class UdpMdnsTransport implements MdnsTransport {
  UdpMdnsTransport._(this._socket);

  static final InternetAddress group = InternetAddress('224.0.0.251');
  static const int port = 5353;

  final RawDatagramSocket _socket;
  final StreamController<MdnsDatagram> _datagrams =
      StreamController<MdnsDatagram>.broadcast();
  StreamSubscription<RawSocketEvent>? _sub;

  /// Binds 0.0.0.0:5353 shared (SO_REUSEADDR) with whatever else listens there
  /// (systemd-resolved, browsers) and joins the group on every IPv4 interface.
  static Future<UdpMdnsTransport> bind() async {
    final RawDatagramSocket socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    try {
      socket
        ..multicastLoopback = true
        ..multicastHops = 255;
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      bool joined = false;
      for (final NetworkInterface iface in interfaces) {
        try {
          socket.joinMulticast(group, iface);
          joined = true;
        } on SocketException catch (e, stack) {
          // One interface refusing (down, no multicast) must not stop the others.
          ErrorLogService.instance.log(
            'Mdns.joinMulticast ${iface.name}',
            e,
            stack,
          );
        }
      }
      if (!joined) socket.joinMulticast(group);
    } catch (_) {
      socket.close();
      rethrow;
    }
    final UdpMdnsTransport transport = UdpMdnsTransport._(socket);
    transport._sub = socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = socket.receive()) != null) {
        transport._datagrams.add(MdnsDatagram(d!.data, d.address, d.port));
      }
    });
    return transport;
  }

  @override
  Stream<MdnsDatagram> get datagrams => _datagrams.stream;

  @override
  void sendMulticast(Uint8List data) => _socket.send(data, group, port);

  @override
  void sendTo(Uint8List data, InternetAddress address, int port) =>
      _socket.send(data, address, port);

  @override
  Future<List<InternetAddress>> localAddresses() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return <InternetAddress>[
      for (final NetworkInterface iface in interfaces) ...iface.addresses,
    ];
  }

  @override
  void close() {
    unawaited(_sub?.cancel());
    _socket.close();
    unawaited(_datagrams.close());
  }
}

// ── Responder ───────────────────────────────────────────────────────────

/// Answers queries for one service instance and announces it on start.
class MdnsServiceResponder {
  MdnsServiceResponder({
    required MdnsTransport transport,
    required String serviceType,
    required String instanceName,
    required String hostLabel,
    required this.port,
    required this.attributes,
    this.ttlSeconds = 120,
  }) : _transport = transport,
       serviceName = MdnsName.parse('$serviceType.local'),
       instance = MdnsName.parse('$serviceType.local').child(instanceName),
       host = MdnsName(<String>[hostLabel, 'local']);

  static final MdnsName _servicesMeta = MdnsName.parse(
    '_services._dns-sd._udp.local',
  );

  final MdnsTransport _transport;
  final MdnsName serviceName;
  final MdnsName instance;
  final MdnsName host;
  final int port;
  final Map<String, String> attributes;
  final int ttlSeconds;

  StreamSubscription<MdnsDatagram>? _sub;
  Timer? _reannounce;

  Future<void> start() async {
    if (_sub != null) return;
    _sub = _transport.datagrams.listen(_onDatagram);
    await _announce();
    // RFC 6762 §8.3: announce at least twice, one second apart.
    _reannounce = Timer(
      const Duration(seconds: 1),
      () => unawaited(_announce()),
    );
  }

  Future<void> stop() async {
    _reannounce?.cancel();
    _reannounce = null;
    if (_sub == null) return;
    await _sub!.cancel();
    _sub = null;
    // Goodbye: TTL 0 tells caches to drop us now instead of in two minutes.
    _transport.sendMulticast(
      encodeMdnsMessage(
        MdnsMessage(
          isResponse: true,
          answers: <MdnsRecord>[
            MdnsPtrRecord(serviceName, 0, instance),
            MdnsSrvRecord(instance, 0, port: port, target: host),
            MdnsTxtRecord(instance, 0, attributes),
          ],
        ),
      ),
    );
  }

  Future<void> _announce() async {
    if (_sub == null) return;
    final List<MdnsRecord> hostRecords = await _addressRecords(null);
    _transport.sendMulticast(
      encodeMdnsMessage(
        MdnsMessage(
          isResponse: true,
          answers: <MdnsRecord>[
            MdnsPtrRecord(serviceName, ttlSeconds, instance),
            MdnsSrvRecord(instance, ttlSeconds, port: port, target: host),
            MdnsTxtRecord(instance, ttlSeconds, attributes),
            ...hostRecords,
          ],
        ),
      ),
    );
  }

  /// A records, the address sharing a /24 with [peer] first: browsers take the
  /// first IPv4, and a multi-homed host must not hand out its docker bridge.
  Future<List<MdnsRecord>> _addressRecords(InternetAddress? peer) async {
    final List<InternetAddress> addrs = (await _transport.localAddresses())
        .where(
          (InternetAddress a) =>
              a.type == InternetAddressType.IPv4 && !a.isLoopback,
        )
        .toList();
    if (peer != null) {
      final List<int> p = peer.rawAddress;
      int score(InternetAddress a) {
        final List<int> r = a.rawAddress;
        return r[0] == p[0] && r[1] == p[1] && r[2] == p[2] ? 0 : 1;
      }

      addrs.sort((InternetAddress a, InternetAddress b) => score(a) - score(b));
    }
    return <MdnsRecord>[
      for (final InternetAddress a in addrs) MdnsARecord(host, ttlSeconds, a),
    ];
  }

  Future<void> _onDatagram(MdnsDatagram datagram) async {
    final MdnsMessage? query = decodeMdnsMessage(datagram.data);
    if (query == null || query.isResponse) return;
    final List<MdnsRecord> answers = <MdnsRecord>[];
    final List<MdnsRecord> additionals = <MdnsRecord>[];
    bool wantHost = false;
    for (final MdnsQuestion q in query.questions) {
      final bool any = q.type == _typeAny;
      if (q.name == serviceName && (any || q.type == _typePtr)) {
        answers.add(MdnsPtrRecord(serviceName, ttlSeconds, instance));
        additionals
          ..add(MdnsSrvRecord(instance, ttlSeconds, port: port, target: host))
          ..add(MdnsTxtRecord(instance, ttlSeconds, attributes));
        wantHost = true;
      } else if (q.name == _servicesMeta && (any || q.type == _typePtr)) {
        answers.add(MdnsPtrRecord(_servicesMeta, ttlSeconds, serviceName));
      } else if (q.name == instance) {
        if (any || q.type == _typeSrv) {
          answers.add(
            MdnsSrvRecord(instance, ttlSeconds, port: port, target: host),
          );
          wantHost = true;
        }
        if (any || q.type == _typeTxt) {
          answers.add(MdnsTxtRecord(instance, ttlSeconds, attributes));
        }
      } else if (q.name == host && (any || q.type == _typeA)) {
        answers.addAll(await _addressRecords(datagram.address));
      }
    }
    if (answers.isEmpty) return;
    if (wantHost) additionals.addAll(await _addressRecords(datagram.address));
    if (_sub == null) return; // stopped while building the answer
    if (datagram.port != UdpMdnsTransport.port) {
      // Legacy unicast querier (RFC 6762 §6.7): reply to its port, echo id + questions.
      _transport.sendTo(
        encodeMdnsMessage(
          MdnsMessage(
            id: query.id,
            isResponse: true,
            questions: query.questions,
            answers: answers,
            additionals: additionals,
          ),
        ),
        datagram.address,
        datagram.port,
      );
      return;
    }
    _transport.sendMulticast(
      encodeMdnsMessage(
        MdnsMessage(
          isResponse: true,
          answers: answers,
          additionals: additionals,
        ),
      ),
    );
  }
}

// ── Browser ─────────────────────────────────────────────────────────────

sealed class MdnsBrowseEvent {
  const MdnsBrowseEvent(this.name);

  /// The instance label (the human-readable service name).
  final String name;
}

final class MdnsServiceResolved extends MdnsBrowseEvent {
  const MdnsServiceResolved(
    super.name, {
    required this.hostname,
    required this.hostAddresses,
    required this.port,
    required this.attributes,
  });

  final String hostname;
  final List<String> hostAddresses;
  final int port;
  final Map<String, String> attributes;

  bool sameAs(MdnsServiceResolved o) =>
      o.hostname == hostname &&
      o.port == port &&
      _listEquals(o.hostAddresses, hostAddresses) &&
      o.attributes.length == attributes.length &&
      attributes.entries.every(
        (MapEntry<String, String> e) => o.attributes[e.key] == e.value,
      );
}

final class MdnsServiceLost extends MdnsBrowseEvent {
  const MdnsServiceLost(super.name);
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Cached<T> {
  _Cached(this.value, this.expires);
  final T value;
  final DateTime expires;
}

/// Browses one service type: queries, caches PTR / SRV / TXT / A answers with
/// their TTLs, asks for missing pieces, and reports instances that become
/// resolvable or stop being so (goodbye, or a record expired without refresh).
class MdnsServiceBrowser {
  MdnsServiceBrowser({
    required MdnsTransport transport,
    required String serviceType,
    @visibleForTesting DateTime Function()? clock,
  }) : _transport = transport,
       _serviceName = MdnsName.parse('$serviceType.local'),
       _now = clock ?? DateTime.now;

  final MdnsTransport _transport;
  final MdnsName _serviceName;
  final DateTime Function() _now;
  final StreamController<MdnsBrowseEvent> _events =
      StreamController<MdnsBrowseEvent>.broadcast();

  final Map<MdnsName, _Cached<void>> _ptr = <MdnsName, _Cached<void>>{};
  final Map<MdnsName, _Cached<MdnsSrvRecord>> _srv =
      <MdnsName, _Cached<MdnsSrvRecord>>{};
  final Map<MdnsName, _Cached<Map<String, String>>> _txt =
      <MdnsName, _Cached<Map<String, String>>>{};
  final Map<MdnsName, Map<String, DateTime>> _a =
      <MdnsName, Map<String, DateTime>>{};
  final Map<MdnsName, MdnsServiceResolved> _reported =
      <MdnsName, MdnsServiceResolved>{};
  final Map<MdnsName, DateTime> _followUpSent = <MdnsName, DateTime>{};

  StreamSubscription<MdnsDatagram>? _sub;
  final List<Timer> _timers = <Timer>[];

  Stream<MdnsBrowseEvent> get events => _events.stream;

  Future<void> start() async {
    if (_sub != null) return;
    _sub = _transport.datagrams.listen(
      (MdnsDatagram d) => debugReceive(d.data),
    );
    _query(<MdnsQuestion>[MdnsQuestion(_serviceName, _typePtr)]);
    // RFC 6762 §5.2: back off the first queries, then refresh steadily.
    _timers
      ..add(Timer(const Duration(seconds: 1), _queryService))
      ..add(Timer(const Duration(seconds: 3), _queryService))
      ..add(Timer.periodic(const Duration(seconds: 20), (_) => _queryService()))
      ..add(Timer.periodic(const Duration(seconds: 5), (_) => debugSweep()));
  }

  Future<void> stop() async {
    for (final Timer t in _timers) {
      t.cancel();
    }
    _timers.clear();
    await _sub?.cancel();
    _sub = null;
    if (!_events.isClosed) await _events.close();
  }

  void _queryService() =>
      _query(<MdnsQuestion>[MdnsQuestion(_serviceName, _typePtr)]);

  void _query(List<MdnsQuestion> questions) {
    if (_sub == null) return;
    _transport.sendMulticast(
      encodeMdnsMessage(MdnsMessage(isResponse: false, questions: questions)),
    );
  }

  /// Feeds one received packet (the transport listener; tests call it directly).
  @visibleForTesting
  void debugReceive(Uint8List data) {
    final MdnsMessage? message = decodeMdnsMessage(data);
    if (message == null || !message.isResponse) return;
    final DateTime now = _now();
    for (final MdnsRecord r in message.allRecords) {
      final DateTime expires = now.add(Duration(seconds: r.ttl));
      switch (r) {
        case MdnsPtrRecord():
          if (r.name != _serviceName) continue;
          if (r.ttl == 0) {
            _ptr.remove(r.target);
          } else {
            _ptr[r.target] = _Cached<void>(null, expires);
          }
        case MdnsSrvRecord():
          if (r.ttl == 0) {
            _srv.remove(r.name);
          } else {
            _srv[r.name] = _Cached<MdnsSrvRecord>(r, expires);
          }
        case MdnsTxtRecord():
          if (r.ttl == 0) {
            _txt.remove(r.name);
          } else {
            _txt[r.name] = _Cached<Map<String, String>>(r.attributes, expires);
          }
        case MdnsARecord():
          final Map<String, DateTime> addrs = _a.putIfAbsent(
            r.name,
            () => <String, DateTime>{},
          );
          if (r.ttl == 0) {
            addrs.remove(r.address.address);
          } else {
            addrs[r.address.address] = expires;
          }
      }
    }
    _reconcile(now);
  }

  /// Drops expired records and reports what changed (the 5 s timer; tests
  /// call it after moving the clock).
  @visibleForTesting
  void debugSweep() {
    final DateTime now = _now();
    _ptr.removeWhere((_, _Cached<void> c) => !c.expires.isAfter(now));
    _srv.removeWhere((_, _Cached<MdnsSrvRecord> c) => !c.expires.isAfter(now));
    _txt.removeWhere(
      (_, _Cached<Map<String, String>> c) => !c.expires.isAfter(now),
    );
    for (final Map<String, DateTime> addrs in _a.values) {
      addrs.removeWhere((_, DateTime e) => !e.isAfter(now));
    }
    _reconcile(now);
  }

  void _reconcile(DateTime now) {
    if (_events.isClosed) return;
    final List<MdnsQuestion> missing = <MdnsQuestion>[];
    for (final MdnsName instance in _ptr.keys) {
      final MdnsSrvRecord? srv = _srv[instance]?.value;
      final List<String> addrs = srv == null
          ? const <String>[]
          : (_a[srv.target]?.keys.toList() ?? const <String>[]);
      if (srv == null || addrs.isEmpty || !_txt.containsKey(instance)) {
        final DateTime? last = _followUpSent[instance];
        if (last == null ||
            now.difference(last) >= const Duration(seconds: 2)) {
          _followUpSent[instance] = now;
          if (srv == null) missing.add(MdnsQuestion(instance, _typeSrv));
          if (!_txt.containsKey(instance)) {
            missing.add(MdnsQuestion(instance, _typeTxt));
          }
          if (srv != null && addrs.isEmpty) {
            missing.add(MdnsQuestion(srv.target, _typeA));
          }
        }
        // Wait for TXT too: Fushi keys peers by its `id` attribute, and
        // reporting first without it would list the same peer twice.
        continue;
      }
      final MdnsServiceResolved resolved = MdnsServiceResolved(
        instance.labels.first,
        hostname: srv.target.toString(),
        hostAddresses: addrs,
        port: srv.port,
        attributes: _txt[instance]?.value ?? const <String, String>{},
      );
      final MdnsServiceResolved? before = _reported[instance];
      if (before == null || !before.sameAs(resolved)) {
        _reported[instance] = resolved;
        _events.add(resolved);
      }
    }
    // Reported instances that are no longer resolvable are gone.
    final List<MdnsName> gone = <MdnsName>[
      for (final MdnsName instance in _reported.keys)
        if (!_ptr.containsKey(instance) ||
            _srv[instance] == null ||
            (_a[_srv[instance]!.value.target]?.isEmpty ?? true))
          instance,
    ];
    for (final MdnsName instance in gone) {
      final MdnsServiceResolved lost = _reported.remove(instance)!;
      _followUpSent.remove(instance);
      _events.add(MdnsServiceLost(lost.name));
    }
    if (missing.isNotEmpty) _query(missing);
  }
}
