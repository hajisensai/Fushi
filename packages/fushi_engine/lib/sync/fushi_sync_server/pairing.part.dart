part of '../fushi_sync_server.dart';

/// 配对与发现域（B3 按域拆出）：ping / capabilities、pair v1 / v2 / confirm、PIN 限流、
/// 配对会话 TTL 与上限。公开回调（onPairRequest 等）留在 [FushiSyncServer] 本体；
/// 方法逐字搬自 FushiSyncServer。
extension _FushiSyncServerPairing on FushiSyncServer {
  Future<shelf.Response> _handlePair(shelf.Request request) async {
    if (request.method.toUpperCase() != 'POST') return shelf.Response(405);
    final Future<bool> Function(FushiPairRequest)? approve = onPairRequest;
    // No UI wired to approve → never hand out the token unattended. A distinct
    // reason lets the client say "peer not ready" instead of "peer declined".
    if (approve == null) return _pairDenied('unavailable');
    // BUG-1555：v1 没有 PIN 概念——它只靠 host 点一下「允许」就发权限最大的**共享**
    // token（不可逐台吊销）。v2 为公网 / 跨网段入站强制 PIN + HMAC，而 v1 同一条
    // 入站链路完全绕开这套：攻击者只需改发 /api/pair，host 屏上弹的就是一个普通
    // 「某设备请求配对」框，误点一次即永久失守。故用与 v2 **同一判据**
    // ([FushiPairingProtocol.computePinRequired]) 前置拦截：本会话必须 PIN 时直接
    // 拒 v1（reason='upgrade_required'，让 client 提示升级），压根不弹审批框。
    //
    // 兼容性：LAN 内且 host 未开「LAN 也要 PIN」时（默认）v1 行为逐字不变，
    // 旧客户端继续可配对；变的只是「本就该要 PIN 的会话」——那些会话以前能拿到
    // 共享 token 本身就是漏洞，现在必须走 v2（Hibiki 自己的 client 早已先试 v2，
    // 只在对端不支持 v2 时才回落 v1）。
    final String? pairRemote = _remoteAddress(request);
    final bool v1PinRequired = FushiPairingProtocol.computePinRequired(
      isLanPeer: _isLanPeerRequest(request, pairRemote),
      lanRequiresPin:
          await (lanRequiresPinProvider?.call() ?? Future<bool>.value(false)),
    );
    if (v1PinRequired) return _pairDenied('upgrade_required');
    String? name;
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    final String? reported = body?['name']?.toString().trim();
    // Reject a "localhost"/loopback advertisement so it is never stored as this
    // peer's device name — the paired-devices list would otherwise show
    // "localhost" instead of a real name (TODO-1356).
    if (reported != null &&
        reported.isNotEmpty &&
        !isMeaninglessDeviceName(reported)) {
      name = reported;
    }
    final bool approved = await approve(FushiPairRequest(
      deviceName: name,
      remoteAddress: pairRemote,
    ));
    if (!approved) return _pairDenied('declined');
    return jsonResponse(<String, dynamic>{'token': _token});
  }

  /// A 403 carrying a machine-readable [reason] ('declined' | 'unavailable' |
  /// 'upgrade_required' | 'expired') so the client can distinguish a real
  /// refusal from a peer that has no approval handler wired, from a v1 client
  /// that this host refuses to pair without a PIN (BUG-1555), and from a
  /// pairing session that timed out (BUG-1556). Older peers reply with a
  /// plain-text body instead, which the client treats as 'unavailable'.
  shelf.Response _pairDenied(String reason) => shelf.Response(
        403,
        body: jsonEncode(<String, String>{'reason': reason}),
        headers: <String, String>{'Content-Type': 'application/json'},
      );

  /// TODO-961 M1: POST /api/pair/v2 {name, clientNonce} → 200 {sessionId,
  /// pinRequired, hostNonce}。仅创建会话、决定是否需要 PIN，并把 host 生成的 PIN
  /// 喂给审批弹窗显示——此阶段 **不** 派 token、**不** 弹「允许/拒绝」（那在
  /// confirm 阶段，双重确认）。PIN 绝不进响应 body。
  Future<shelf.Response> _handlePairV2(shelf.Request request) async {
    if (request.method.toUpperCase() != 'POST') return shelf.Response(405);
    // No approval UI wired → never start a pairing handshake unattended.
    if (onPairRequest == null) return _pairDenied('unavailable');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    final String? clientNonce = body?['clientNonce']?.toString();
    if (clientNonce == null || clientNonce.trim().isEmpty) {
      return shelf.Response(400, body: 'Missing clientNonce');
    }
    final String? reportedName = body?['name']?.toString().trim();
    // Drop a "localhost"/loopback advertisement (never a real device name) so it
    // is not persisted as the peer's name in the paired-devices list (TODO-1356).
    final String? deviceName = (reportedName != null &&
            reportedName.isNotEmpty &&
            !isMeaninglessDeviceName(reportedName))
        ? reportedName
        : null;
    // TODO-961 M1b: client 自报稳定 deviceId（per-peer token 落库的 UNIQUE 身份）。
    // 旧 client 不带此字段 → null → confirm 回退共享 token（兼容）。
    final String? reportedDeviceId = body?['clientDeviceId']?.toString().trim();
    final String? clientDeviceId =
        (reportedDeviceId != null && reportedDeviceId.isNotEmpty)
            ? reportedDeviceId
            : null;
    final String? remote = _remoteAddress(request);
    final String? tunnelPeer = request.context[kFushiP2pPeer] as String?;

    // 扫码 / 复制链接配对：凭 host 签发的一次性票据
    // （docs/specs/2026-09-28-interconnect-remote-reach.md §4）。老 client 不带此字段。
    final String? ticketRef = body?['ticket']?.toString().trim();
    if (ticketRef != null && ticketRef.isNotEmpty) {
      return _startTicketPairSession(
        ticketRef: ticketRef,
        clientNonce: clientNonce,
        deviceName: deviceName,
        remote: remote,
        clientDeviceId: clientDeviceId,
        tunnelPeer: tunnelPeer,
      );
    }

    final bool isLanPeer = _isLanPeerRequest(request, remote);
    final bool lanRequiresPin =
        await (lanRequiresPinProvider?.call() ?? Future<bool>.value(false));
    final bool pinRequired = FushiPairingProtocol.computePinRequired(
      isLanPeer: isLanPeer,
      lanRequiresPin: lanRequiresPin,
    );

    final String sessionId = FushiPairingProtocol.generateNonce();
    final String hostNonce = FushiPairingProtocol.generateNonce();
    final FushiPairSession session = FushiPairSession(
      sessionId: sessionId,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      // PIN 先用安全随机兜底，下面交给 host UI 供给器（若接线）覆盖为屏显值。
      pin: FushiPairingProtocol.generatePin(),
      pinRequired: pinRequired,
      deviceName: deviceName,
      remoteAddress: remote,
      createdAt: _now(),
      clientDeviceId: clientDeviceId,
      tunnelPeer: tunnelPeer,
    );
    // 先 prune 过期会话 + 守上限：杜绝「只发 pair/v2 不 confirm」的慢速 DoS 把
    // _pairSessions 撑爆（对照 audio/video token 的 prune 模式）。
    _prunePairSessions();
    _enforcePairSessionCap();
    // 同步回收已冷却的 PIN 失败记录，防限速器内存随开会话数无界增长。
    _pinRateLimiter.prune(_now());

    // host UI 供给器返回真正显示给用户的 PIN（同值用于 confirm 重算比对）。未接线
    // 时保留随机兜底 PIN——它不显示给任何人，故 pinRequired 会话无法被 confirm（拒）。
    final String shownPin = onPairPinGenerated?.call(session) ?? session.pin;

    // TODO-1296 / BUG-592: pinRequired（公网 / 跨网段 / host 要求 PIN）会话在 CREATE
    // 阶段就弹 host 审批——审批弹窗会显示本会话 PIN，让 client 被要求输入前 host 屏上
    // 已经有 PIN 可读。修复「公网配对根本看不到 PIN」的时序死锁：旧实现只在 confirm 且
    // pinProof 校验通过后才弹审批显示 PIN，而 client 必须先输对 PIN 才能过校验 → PIN 永
    // 远不显示、配对永远走不通。免 PIN 会话（LAN 自动发现且 host 允许免 PIN）审批仍留在
    // confirm（本就无 PIN 可显示，行为零变化，Never break userspace）。
    if (pinRequired) {
      final bool approved = await onPairRequest!(FushiPairRequest(
        deviceName: deviceName,
        remoteAddress: remote,
        // pinVerified 尚未校验（那在 confirm）；pinRequired=true 让审批弹窗显示 PIN。
        pinVerified: null,
        pinRequired: true,
      ));
      if (!approved) return _pairDenied('declined');
    }

    // BUG-1556：TTL 从**会话真正开始可用的那一刻**起算，而不是请求入口。
    // 上面那句 `await onPairRequest!` 是人手审批（host 手机在口袋里 / 用户正在
    // 忙），完全可能超过整个 90s TTL；若沿用请求入口的时刻，会话会在被写进
    // [_pairSessions] 的那一刻就已经过期，client 紧接着的 confirm 必被 prune 掉，
    // 且当时还被报成「对端拒绝」——host 分明刚点了允许。client 真正能开始
    // 输 PIN 的起点就是审批通过，故 TTL 从此刻起算。
    final FushiPairSession stored = FushiPairSession(
      sessionId: sessionId,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      pin: shownPin,
      pinRequired: pinRequired,
      deviceName: deviceName,
      remoteAddress: remote,
      createdAt: _now(),
      clientDeviceId: clientDeviceId,
      tunnelPeer: tunnelPeer,
    );
    _pairSessions[sessionId] = stored;

    // 响应只含 sessionId / pinRequired / hostNonce —— 绝不含 PIN 明文。
    return jsonResponse(<String, dynamic>{
      'sessionId': sessionId,
      'pinRequired': pinRequired,
      'hostNonce': hostNonce,
    });
  }

  /// 票据配对会话：票据 secret 代替 PIN（`pinRequired` 恒 true，confirm 路径与 PIN
  /// 会话逐字相同），host 屏上打开二维码即视为已批准——不弹审批框、不生成屏显 PIN。
  /// 票据不符或过期一律回 'expired'：client 只需说「二维码已失效，请在主机上重新
  /// 打开」，不必区分「被刷新掉了」与「超时了」。
  shelf.Response _startTicketPairSession({
    required String ticketRef,
    required String clientNonce,
    required String? deviceName,
    required String? remote,
    required String? clientDeviceId,
    required String? tunnelPeer,
  }) {
    final FushiPairTicket? ticket = _pairTicket;
    if (ticket == null ||
        !FushiPairingProtocol.constantTimeEquals(ticket.id, ticketRef)) {
      return _pairDenied('expired');
    }
    if (!ticket.isValidAt(_now())) {
      _pairTicket = null;
      return _pairDenied('expired');
    }
    // 一票一会话：建会话即消耗票据。否则拍到二维码的人（直播 / 屏幕共享）能在
    // 5 分钟内预开任意多个会话，合法设备配完、二维码关掉之后照样逐个 confirm
    // 拿 token（审查问题 3）。输错 secret 的合法设备重新打开二维码即可。
    _pairTicket = null;
    _prunePairSessions();
    _enforcePairSessionCap();
    _pinRateLimiter.prune(_now());
    final String sessionId = FushiPairingProtocol.generateNonce();
    final String hostNonce = FushiPairingProtocol.generateNonce();
    _pairSessions[sessionId] = FushiPairSession(
      sessionId: sessionId,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      pin: ticket.secret,
      pinRequired: true,
      deviceName: deviceName,
      remoteAddress: remote,
      createdAt: _now(),
      clientDeviceId: clientDeviceId,
      ticketId: ticket.id,
      tunnelPeer: tunnelPeer,
    );
    return jsonResponse(<String, dynamic>{
      'sessionId': sessionId,
      'pinRequired': true,
      'hostNonce': hostNonce,
    });
  }

  /// TODO-961 M1: POST /api/pair/v2/confirm {sessionId, pinProof} → 200 {token,
  /// hostFingerprint}。校验 pinProof（双 nonce HMAC），通过后 **仍** 需 host 人工
  /// 点允许（双重确认）才派 token。同一 sessionId 二次 confirm（重放）一律拒。
  Future<shelf.Response> _handlePairConfirm(shelf.Request request) async {
    if (request.method.toUpperCase() != 'POST') return shelf.Response(405);
    final Future<bool> Function(FushiPairRequest)? approve = onPairRequest;
    if (approve == null) return _pairDenied('unavailable');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    final String? sessionId = body?['sessionId']?.toString();
    if (sessionId == null || sessionId.trim().isEmpty) {
      return shelf.Response(400, body: 'Missing sessionId');
    }
    // BUG-1556：先**查**再 prune——过期与未知是两回事。旧实现先 prune 再查，
    // 超时的会话在查之前就没了，于是一律报 'declined'（对端拒绝）——用户
    // 去查「对方为什么拒绝我」，而真相是「你输 PIN 太慢，会话过期了」，排查
    // 方向全错。现在过期返回专用 reason='expired'，client 据此说人话。
    final FushiPairSession? found = _pairSessions[sessionId];
    if (found != null &&
        found.createdAt.isBefore(_now().subtract(_pairSessionTtl))) {
      _pairSessions.remove(sessionId);
      // 过期会话同样消耗掉它的 PIN：host 屏上那个常驻 PIN 弹窗该收起，
      // 否则用户盯着一个已经没用的 PIN 继续等（对齐 pinRequired 成功路径）。
      if (found.pinRequired) onPairSessionResolved?.call();
      _prunePairSessions();
      _pinRateLimiter.prune(_now());
      return _pairDenied('expired');
    }
    // 再清掉其余过期会话（不靠后续 create 触发）。
    _prunePairSessions();
    // 同步回收已冷却的 PIN 失败记录（锁定中的保留到期满），防限速器内存泄漏。
    _pinRateLimiter.prune(_now());
    final FushiPairSession? session = _pairSessions[sessionId];
    // 未知会话（伪造 / 已被早前的 prune 清走）或已被消费过（重放）→ 拒。
    // consumed 防同 nonce 二次提交。
    if (session == null || session.consumed) {
      return _pairDenied('declined');
    }
    // 单次消费：无论本次成功失败，会话即作废，杜绝 nonce 重放。
    session.consumed = true;
    _pairSessions.remove(sessionId);

    // TODO-1330 / BUG：pinRequired 会话一旦 confirm 到达，说明 client 已读到 host 屏上
    // 的 PIN（用它算了 proof），host 那个常驻 PIN 弹窗就该收起——无论本次 proof 对错
    // （PIN 已一次性消费，重试要走新会话拿新 PIN）。在此单点触发，避开后面多个 return
    // 分支各自补一遍。免 PIN 会话没有常驻弹窗，不触发。
    // 票据会话没有屏显 PIN 弹窗可收（收了反而会误关同时进行的另一次 PIN 配对）。
    if (session.pinRequired && session.ticketId == null) {
      onPairSessionResolved?.call();
    }

    // TODO-961 M3：本会话来源标识，供爆破限速按来源聚合失败计数。优先 client 自报的
    // 稳定 deviceId，回退来源 IP；二者都缺时为 null → 无稳定身份可锁，退化为不限速的
    // 单会话路径（该路径已被 session.consumed 单次消费保护，一个会话只能撞一次）。
    final String? sourceKey = _pinRateLimitSourceKey(session);
    if (session.pinRequired) {
      // 先查锁定态（再触碰 PIN 比对）：锁定则直接拒，杜绝继续撞。锁定判定只看来源与
      // 时钟，与 PIN 内容完全无关，故不引入「前缀正确就更慢」的计时侧信道。
      if (sourceKey != null && _pinRateLimiter.isLockedOut(sourceKey, _now())) {
        return _pairRateLimited();
      }
      final String? pinProof = body?['pinProof']?.toString();
      if (pinProof == null || pinProof.trim().isEmpty) {
        // 缺 proof 同样计一次失败：否则攻击者可用「开会话→空 proof」零成本探测锁定态
        // 之外的东西。记后若已锁定，返回 429 让 client 知道被限速。
        if (sourceKey != null &&
            _pinRateLimiter.recordFailure(sourceKey, _now())) {
          return _pairRateLimited();
        }
        // 401：PIN 校验未通过（缺 proof）——不再问 host（不弹窗）。
        return _pairUnauthorized();
      }
      final bool ok = FushiPairingProtocol.verifyPinProof(
        pin: session.pin,
        clientNonce: session.clientNonce,
        hostNonce: session.hostNonce,
        submittedProof: pinProof,
      );
      if (!ok) {
        // 记一次来源级失败；若因此达阈值进入锁定，返回 429（限速），否则 401（PIN 错）。
        if (sourceKey != null &&
            _pinRateLimiter.recordFailure(sourceKey, _now())) {
          return _pairRateLimited();
        }
        return _pairUnauthorized();
      }
    }

    // TODO-1296 / BUG-592: pinRequired 会话的 host 审批已在 CREATE 阶段完成——会话能
    // 存在于 _pairSessions 即代表 host 当时已点允许（见 _handlePairV2），故此处不再二次
    // 弹窗，只凭 pinProof 校验通过即派 token（双重确认 = 早前的人工允许 + 此刻的 proof
    // 校验，两者仍缺一不可）。免 PIN 会话（pinRequired=false）没有 CREATE 阶段审批，仍在
    // 此弹审批（无 PIN 可显示，行为不变）。
    if (!session.pinRequired) {
      final bool approved = await approve(FushiPairRequest(
        deviceName: session.deviceName,
        remoteAddress: session.remoteAddress,
        pinVerified: true,
        pinRequired: false,
      ));
      if (!approved) return _pairDenied('declined');
    }

    // TODO-961 M3：成功配对 → 清零该来源的 PIN 失败计数与锁定态（不株连未来尝试）。
    if (sourceKey != null) _pinRateLimiter.recordSuccess(sourceKey);
    // 一次性票据：配成一台就作废（二维码被别人再扫一次也没用）。
    if (session.ticketId != null && _pairTicket?.id == session.ticketId) {
      _pairTicket = null;
    }

    // TODO-961 M1b：per-peer token 派发。仅当 host 接线了落库回调（onPeerPaired）
    // **且** client 上报了稳定 deviceId 时，才生成本设备专属 token 并写库、回给该
    // client。任一缺失（纯协议单测无 DB / 旧 client 不上报 deviceId）则回退共享
    // [_token]——既有行为零变化、老设备继续可配对（Never break userspace）。
    final String issuedToken = await _issuePeerTokenOrFallback(session);
    return jsonResponse(<String, dynamic>{
      'token': issuedToken,
      if (_securityContext != null && _hostFingerprint != null)
        'hostFingerprint': _hostFingerprint,
    });
  }

  /// confirm 成功后派发访问 token：有 [onPeerPaired] 回调且会话带 clientDeviceId
  /// 时生成 per-peer token、经回调落库并清 token 缓存（吊销/新增即时生效），返回该
  /// token；否则回退共享 [_token]（无 DB 接线 / 旧 client 无 deviceId 的兼容路径）。
  Future<String> _issuePeerTokenOrFallback(FushiPairSession session) async {
    final Future<void> Function(FushiPairedPeerRegistration)? persist =
        onPeerPaired;
    final String? peerId = session.clientDeviceId?.trim();
    if (persist == null || peerId == null || peerId.isEmpty) {
      return _token;
    }
    final String peerToken = FushiSyncServer.generateToken();
    await persist(FushiPairedPeerRegistration(
      peerId: peerId,
      token: peerToken,
      deviceName: session.deviceName,
      remoteAddress: session.remoteAddress,
    ));
    // 新 token 立即受理：清缓存促下次 auth 从 provider 重载（含刚写入的这行）。
    invalidatePeerTokenCache();
    return peerToken;
  }

  /// 401，机器可读 reason='pin'：PIN proof 校验未通过。与 403/declined 区分，让
  /// client 提示「PIN 错误，请重输」而非「对端拒绝」。绝不在 body 里回显任何 PIN。
  shelf.Response _pairUnauthorized() => shelf.Response(
        401,
        body: jsonEncode(<String, String>{'reason': 'pin'}),
        headers: <String, String>{'Content-Type': 'application/json'},
      );

  /// TODO-961 M3：429，机器可读 reason='rate_limited'：该来源 PIN 失败过多已被锁定
  /// 退避。与 401/pin 区分，让 client 提示「尝试过多，请稍后再试」而非「PIN 错误」。
  /// 绝不回显剩余锁定时长的精确值以外的信息，也绝不泄露 PIN 是否部分正确。
  shelf.Response _pairRateLimited() => shelf.Response(
        429,
        body: jsonEncode(<String, String>{'reason': 'rate_limited'}),
        headers: <String, String>{'Content-Type': 'application/json'},
      );

  /// TODO-963 M2: 无鉴权轻量探测。手动输入 IP 的 client 在「填 IP → 探测 → 配对」流程
  /// 里用它确认地址可达、读 host 展示名 + 是否支持 v2 配对 + （TLS 开时）host 证书指纹
  /// 供 TOFU 钉扎。只读、不含任何数据/凭据。绝不回传 token。
  shelf.Response _handlePing() {
    return jsonResponse(<String, dynamic>{
      // 互联 wire 服务字段：与 client 侧 probeFushiPing 的 app == 'fushi'
      // 同版本对切（R11 已接受跨版本配对探测互不识别）。
      'app': 'fushi',
      'pairing': <String, dynamic>{'v2': true},
      'tls': <String, dynamic>{
        'enabled': _securityContext != null,
        if (_hostFingerprint != null) 'fingerprint': _hostFingerprint,
      },
      if (_deviceName != null && _deviceName.isNotEmpty)
        'deviceName': _deviceName,
      // 选路探测的身份核对：学到的 LAN 地址换个网络可能指向**别人的** Fushi
      // host，明文 http 下只看 app=='fushi' 会选中它并把 token 发过去。hostId
      // 本就在 LAN 广播 TXT 里公开，不是秘密。
      if (hostId != null) 'hostId': hostId,
    });
  }

  Future<shelf.Response> _handleCapabilities() async {
    final bool lib = _libraryService != null;
    // 漫画 P3 能力协商：仅接线了 OCR 任务管理器的 host 带 `mangaOcr` 字段；老
    // host 响应里没有该字段 → client 隐藏「已配对主机」OCR 选项（零破坏）。
    final Map<String, Object?>? mangaOcr = await _mangaOcrJobs?.capability();
    final Map<String, Object?>? jobs = await _hostJobs?.capability();
    final Map<String, Object?>? downloads = await _downloads?.capability();
    final Map<String, Object?>? subscriptions = await _subscriptions?.capability();
    final Map<String, Object?>? assistant = await _assistant?.capability();
    return jsonResponse(<String, dynamic>{
      if (mangaOcr != null) 'mangaOcr': mangaOcr,
      // 通用任务能力位：`jobs.kinds` + 每种 kind 的就绪信息；老 client 读不到也不崩。
      if (jobs != null) 'jobs': jobs,
      if (downloads != null) 'downloads': downloads,
      if (subscriptions != null) 'subscriptions': subscriptions,
      if (assistant != null) 'assistant': assistant,
      // 查词 / 制卡 / 查词历史 / 游戏串流：这台 host 是否接了对应 service（老 host
      // 无这些字段，client 照旧以端点 404 判断）。只说「懂不懂这条路由」，不代表此刻
      // 一定成功——例如制卡还要 host 已登录 Anki、查词还要 host 装了词典。
      'lookup': <String, dynamic>{
        'dictionary': _remoteLookupService != null,
        'history': _historyService != null,
      },
      'mining': _miningService != null,
      'gameStream': _gameStreamService != null,
      'liveLibrary': <String, dynamic>{
        'dictionaries': lib,
        'books': lib,
        'audio': lib,
        'videos': lib,
        // 互联漫画源（按页在线阅读，`/api/library/manga/**`）。老 host 无此字段 →
        // client 的漫画「来源」页把这一行标成「对端版本过低」，而不是让用户点进去
        // 对着一屏 404 反复重试。与既有 `mangaOcr` 能力位同一范式。
        'manga': _libraryService is MangaLibraryHost,
        // 视频刮削元数据同步 / 远程刮削 / 代刮回写（`/api/library/metadata*`）。老
        // host 无此字段 → client 跳过元数据同步并隐藏远程刮削入口。
        'videoMetadata': _libraryService is VideoMetadataHost,
        // 互联标签同步（`/api/library/tags`）。老 host 无此字段 / false → client
        // 跳过标签维度（下载时搬一次标签的旧行为不受影响）。
        'tags': _libraryService is TagSyncHost,
        // 弱网实时转码（`/streamurl?maxHeight=&maxBitrate=`）。老 host 无此字段 →
        // client 不显示画质档，行为与从前一致。字段随用户开关与本机 ffmpeg 可用性
        // 实时变化，不是启动时的快照；最终真相仍是 `/streamurl` 回的 `transcoded`。
        'videoTranscode': lib && _videoTranscodeEnabled,
        // 远端导入 / 重定时字幕「设为这一集的默认字幕」（`PUT .../subtitle` 带
        // `X-Hibiki-Subtitle-Default: 1`，host 按自己的学习语言定后缀、旧 sidecar
        // 改名 `.fushi-bak` 让位）。老 host 无此字段 → client **不上传**：老 host
        // 不认那个 header，会走 live push 的旧路径按 client 报的后缀落盘，
        // `rename` 直接覆盖 host 上同名的旧字幕且不留备份（BUG-2728）。
        'videoSubtitleDefault': _libraryService is VideoSubtitleDefaultHost,
        // TMDB 备选排序（`/api/library/metadata/episode-group*`）。
        'videoMetadataOrdering': _libraryService is VideoMetadataOrderingHost,
        'serviceConfig': _securityContext != null &&
            _libraryService is InterconnectServiceConfigHost,
        // 互联「配置文件」（Profile）双向搬运：与 serviceConfig 同门槛（必须 TLS）。
        // 能力位只说「这台 host 懂这个端点」，不代表此刻允许——端点还会再查一次
        // 用户开关，关着时返回 403，client 如实报错而不是当成不支持。
        'profileTransfer': _securityContext != null &&
            _libraryService is InterconnectProfileHost,
      },
      // TODO-961 M1 能力协商（设计稿 §1.1 / §2.5）：老 client 读不到也不崩。
      'tls': <String, dynamic>{
        'enabled': _securityContext != null,
        if (_hostFingerprint != null) 'fingerprint': _hostFingerprint,
      },
      'pairing': <String, dynamic>{'v2': true},
    });
  }

  /// GET /api/host/addresses → `{hostId, addresses:[{url, kind}]}`
  /// （docs/specs/2026-09-28-interconnect-remote-reach.md §1）。
  ///
  /// 需鉴权——不放无鉴权的 /api/ping：不向任何能探到端口的人泄露内网拓扑。也不
  /// 并进 capabilities：那是「支持什么」，这是「在哪里」；capabilities 被各功能
  /// 频繁读，每次都枚举网卡是白费。没有 hostId 的 host（老调用方 / 单测）404，
  /// client 无从分组也就不学。
  Future<shelf.Response> _handleHostAddresses() async {
    final String? id = hostId;
    if (id == null) return shelf.Response.notFound('No host id');
    return jsonResponse(<String, dynamic>{
      'hostId': id,
      'addresses': <Map<String, Object?>>[
        for (final InterconnectHostAddress a in await _hostAddresses())
          a.toJson(),
      ],
    });
  }

  /// TODO-961 M1：清掉 [_pairSessionTtl] 之前创建的配对会话。对照
  /// [RemoteAudioTokenStore.prune] / [_pruneVideoTokens]：按 createdAt + 注入的 [_now] 判定，
  /// 可单测。在 pair/v2 创建与 confirm 两处调用，使过期会话既不堆积也不可被 confirm。
  void _prunePairSessions() {
    final DateTime cutoff = _now().subtract(_pairSessionTtl);
    _pairSessions.removeWhere(
      (String _, FushiPairSession s) => s.createdAt.isBefore(cutoff),
    );
  }

  /// TODO-961 M1：守住会话上限。prune 之后仍超过 [_maxPairSessions] 时，按 createdAt
  /// 淘汰最旧的会话直到回到上限内（攻击者用全新 nonce 高频发起 pair/v2、每个都还在
  /// TTL 内时的兜底）。正常一次一会话（_pairDialogOpen 串行审批），此路径几乎不触发。
  void _enforcePairSessionCap() {
    while (_pairSessions.length >= _maxPairSessions) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final MapEntry<String, FushiPairSession> e
          in _pairSessions.entries) {
        if (oldestAt == null || e.value.createdAt.isBefore(oldestAt)) {
          oldestAt = e.value.createdAt;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _pairSessions.remove(oldestKey);
    }
  }
}

// ── 本域私有的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到
//    宿主类的 static，故提到库顶层）。

/// TODO-961 M1（会话 TTL/上限，对照 audio/video token 的 prune 模式）：只发
/// pair/v2 却不 confirm 的攻击者会留下永久驻留会话（慢速 DoS）。每个会话
/// [_pairSessionTtl] 后过期，超过 [_maxPairSessions] 时先 prune 再淘汰最旧者。
/// TTL 与现有 host 60s 自动 deny（[FushiSyncServerController]）对齐：会话生命周期
/// 不应长于一次审批窗口（留 90s 余量覆盖审批弹窗 + 用户输 PIN）。
const Duration _pairSessionTtl = Duration(seconds: 90);

const int _maxPairSessions = 64;

/// TODO-961 M3：本会话在 PIN 爆破限速里的来源标识。优先 client 自报的稳定
/// deviceId（同一物理设备换 IP 也锁得住），回退请求来源 IP。二者都缺（无稳定身份）
/// 时返回 null → 调用方退化为不限速的单会话路径（已由 consumed 单次消费保护）。
///
/// 隧道会话例外：一律按对端 NodeId 分桶，**不认**自报 deviceId。deviceId 谁都能
/// 冒报（报成受害者的就能把受害者锁在外面），NodeId 是隧道握手证明过的密钥；而
/// 来源 IP 恒为 127.0.0.1 毫无区分度。查不到 NodeId（解析器未接线）时所有这类
/// 会话共用一个桶——宁可误伤也不放开。
String? _pinRateLimitSourceKey(FushiPairSession session) {
  if (session.tunnelPeer != null) return 'p2p:${session.tunnelPeer}';
  if (session.remoteAddress == kFushiP2pRemoteAddress) return 'p2p:?';
  final String? deviceId = session.clientDeviceId?.trim();
  if (deviceId != null && deviceId.isNotEmpty) return 'dev:$deviceId';
  final String? remote = session.remoteAddress?.trim();
  if (remote != null && remote.isNotEmpty) return 'ip:$remote';
  return null;
}

/// 配对的「局域网对端」判据：P2P 隧道进来的请求来源永远是 127.0.0.1，必须按
/// 公网处理（强制 PIN / 票据），否则拿到 NodeId 的任何人都能免 PIN 配上。
bool _isLanPeerRequest(shelf.Request request, String? remote) =>
    request.context[kFushiRequestZone] != 'p2p' &&
    FushiPairingProtocol.isPrivateLanAddress(remote);

/// Source IP of the request's TCP connection, or null when shelf_io did not
/// attach connection info (e.g. some test harnesses).
String? _remoteAddress(shelf.Request request) {
  // P2P 隧道进来的连接在 TCP 层恒为 127.0.0.1：原样上屏会让 host 审批框里的公网
  // 陌生人看起来像「本机」（审查问题 4）。如实标成隧道。
  if (request.context[kFushiRequestZone] == 'p2p') {
    return kFushiP2pRemoteAddress;
  }
  final Object? info = request.context['shelf.io.connection_info'];
  if (info is HttpConnectionInfo) {
    return FushiPairingProtocol.unmapIPv4MappedAddress(
        info.remoteAddress.address);
  }
  return null;
}
