part of '../fushi_sync_server.dart';

/// 配对与发现域（B3 按域拆出）：ping / capabilities、pair v1 / v2 / confirm、PIN 限流、
/// 配对会话 TTL 与上限。公开回调（onPairRequest 等）留在 [FushiSyncServer] 本体；
/// 方法逐字搬自 FushiSyncServer。
extension _FushiSyncServerPairing on FushiSyncServer {
  /// 本请求的来源分类（BUG-4279），见 [_classifyRequestOrigin]。
  _RequestOrigin _requestOrigin(shelf.Request request) {
    final List<String> proxies =
        trustedProxiesProvider?.call() ?? const <String>[];
    FushiAddressRangeSet trusted = FushiAddressRangeSet.empty;
    if (proxies.isNotEmpty) {
      try {
        trusted = FushiAddressRangeSet.parse(proxies);
      } on FormatException {
        // 配置加载处已校验；万一漏进非法条目，按「没有可信代理」处理——只会让
        // 展示 / 限速键退回 TCP 对端，不影响 LAN 判定（带转发头恒按公网）。
        trusted = FushiAddressRangeSet.empty;
      }
    }
    return _classifyRequestOrigin(
      request,
      loopbackPeerIsLan: loopbackPeerIsLan,
      trustedProxies: trusted,
    );
  }

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
    // 共享 token 本身就是漏洞，现在必须走 v2（Fushi 自己的 client 早已先试 v2，
    // 只在对端不支持 v2 时才回落 v1）。
    final _RequestOrigin origin = _requestOrigin(request);
    final String? pairRemote = origin.display;
    final bool v1PinRequired = FushiPairingProtocol.computePinRequired(
      isLanPeer: origin.isLanPeer,
      lanRequiresPin:
          await (lanRequiresPinProvider?.call() ?? Future<bool>.value(false)),
    );
    if (v1PinRequired) return _pairDenied('upgrade_required');
    String? name;
    final Map<String, dynamic>? body = await readJsonObjectBody(
      request,
      maxBytes: kPairingBodyMaxBytes,
    );
    final String? reported = body?['name']?.toString().trim();
    // Reject a "localhost"/loopback advertisement so it is never stored as this
    // peer's device name — the paired-devices list would otherwise show
    // "localhost" instead of a real name (TODO-1356).
    if (reported != null &&
        reported.isNotEmpty &&
        !isMeaninglessDeviceName(reported)) {
      name = reported;
    }
    final bool approved = await approve(
      FushiPairRequest(deviceName: name, remoteAddress: pairRemote),
    );
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
    final Map<String, dynamic>? body = await readJsonObjectBody(
      request,
      maxBytes: kPairingBodyMaxBytes,
    );
    final String? clientNonce = body?['clientNonce']?.toString();
    if (clientNonce == null || clientNonce.trim().isEmpty) {
      return shelf.Response(400, body: 'Missing clientNonce');
    }
    final String? reportedName = body?['name']?.toString().trim();
    // Drop a "localhost"/loopback advertisement (never a real device name) so it
    // is not persisted as the peer's name in the paired-devices list (TODO-1356).
    final String? deviceName =
        (reportedName != null &&
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
    // 互联设备公钥（interconnect_device_key.dart）：只在带了 deviceId 时才有意义——它要
    // 和 deviceId 一起被 confirm 里的签名绑定。形状不对当没上报（旧 client 同样没有）。
    final String? reportedPubkey = body?['devicePubkey']?.toString().trim();
    final String? devicePubkey =
        (clientDeviceId != null &&
            reportedPubkey != null &&
            interconnectDeviceKeyFingerprint(reportedPubkey) != null)
        ? reportedPubkey
        : null;
    final _RequestOrigin origin = _requestOrigin(request);
    final String? remote = origin.display;
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
        devicePubkey: devicePubkey,
        origin: origin,
      );
    }

    final bool isLanPeer = origin.isLanPeer;
    final bool lanRequiresPin =
        await (lanRequiresPinProvider?.call() ?? Future<bool>.value(false));
    final bool pinRequired = FushiPairingProtocol.computePinRequired(
      isLanPeer: isLanPeer,
      lanRequiresPin: lanRequiresPin,
    );

    // BUG-4280：本来源或本来源类别因 PIN 失败过多锁定中 → 不建会话、不生成 PIN、
    // 不弹审批 / 不刷无头日志。免 PIN 会话不猜 PIN，不受锁定影响。
    if (pinRequired && _pinLockedOut(origin.originClass, origin.sourceKey)) {
      return _pairRateLimited();
    }
    // 人工批准过的 PIN 会话受淘汰保护（攻击者不经主人点头占不住它们）。
    final bool protectedFromEviction = pinRequired && pinApprovalIsManual;

    // 先 prune 过期会话 + 守本类别上限：杜绝「只发 pair/v2 不 confirm」的慢速 DoS 把
    // _pairSessions 撑爆（对照 audio/video token 的 prune 模式）。类别里全是受保护会话
    // 时腾不出位置 → 429。
    _prunePairSessions();
    if (!_enforcePairSessionCap(origin)) return _pairRateLimited();
    // 同步回收已冷却的 PIN 失败记录，防限速器内存随开会话数无界增长。
    _pinRateLimiter.prune(_now());

    final String sessionId = FushiPairingProtocol.generateNonce();
    final String hostNonce = FushiPairingProtocol.generateNonce();
    // 「这是我的设备」只对上报了设备钥匙的会话提供，且审批结果只存在本会话里
    // （PR #2258 审查问题 1：不按 deviceId 记全局账，PIN 错 / 过期 / 被拒都随会话丢弃）。
    final FushiPairOwnerDeviceGrant? ownerDeviceGrant = devicePubkey != null
        ? FushiPairOwnerDeviceGrant()
        : null;
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
      devicePubkey: devicePubkey,
      ownerDeviceGrant: ownerDeviceGrant,
      sourceKey: origin.sourceKey,
      sourceKeyTrusted: origin.sourceKeyTrusted,
      originClass: origin.originClass,
      protectedFromEviction: protectedFromEviction,
    );

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
      final bool approved = await onPairRequest!(
        FushiPairRequest(
          deviceName: deviceName,
          remoteAddress: remote,
          // pinVerified 尚未校验（那在 confirm）；pinRequired=true 让审批弹窗显示 PIN。
          pinVerified: null,
          pinRequired: true,
          clientDeviceId: clientDeviceId,
          ownerDeviceGrant: ownerDeviceGrant,
        ),
      );
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
      devicePubkey: devicePubkey,
      ownerDeviceGrant: ownerDeviceGrant,
      sourceKey: origin.sourceKey,
      sourceKeyTrusted: origin.sourceKeyTrusted,
      originClass: origin.originClass,
      protectedFromEviction: protectedFromEviction,
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
  /// 票据会话**永远**不授予「我的设备」（没有 [FushiPairOwnerDeviceGrant]）：没有人在
  /// host 屏上为这台设备做过这个选择。设备钥匙照样验签记指纹，供之后手动标记。
  /// 票据不符或过期一律回 'expired'：client 只需说「二维码已失效，请在主机上重新
  /// 打开」，不必区分「被刷新掉了」与「超时了」。
  shelf.Response _startTicketPairSession({
    required String ticketRef,
    required String clientNonce,
    required String? deviceName,
    required String? remote,
    required String? clientDeviceId,
    required String? tunnelPeer,
    required String? devicePubkey,
    required _RequestOrigin origin,
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
    // 腾不出会话位置（本类别全是受保护会话）时不消耗票据，稍后重试仍可用。
    _prunePairSessions();
    if (!_enforcePairSessionCap(origin)) return _pairRateLimited();
    _pairTicket = null;
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
      devicePubkey: devicePubkey,
      sourceKey: origin.sourceKey,
      sourceKeyTrusted: origin.sourceKeyTrusted,
      originClass: origin.originClass,
      // 票据会话凭 192-bit secret，host 屏上打开二维码即视为批准：不被灌满的会话挤掉。
      protectedFromEviction: true,
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
    final Map<String, dynamic>? body = await readJsonObjectBody(
      request,
      maxBytes: kPairingBodyMaxBytes,
    );
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

    // TODO-961 M3 / BUG-4280：来源标识在建会话时由 [_requestOrigin] 算好存进会话
    // （IP，IPv6 按 /64；隧道按 NodeId；**不**认自报 deviceId）。为 null 时不按来源
    // 限速，只受来源类别预算约束（单会话本就被 session.consumed 限成只撞一次）。
    final String? sourceKey = session.sourceKey;
    final bool isTicket = session.ticketId != null;
    if (session.pinRequired) {
      // 先查锁定态（再触碰 PIN 比对）：锁定则直接拒，杜绝继续撞。锁定判定只看来源与
      // 时钟，与 PIN 内容完全无关，故不引入「前缀正确就更慢」的计时侧信道。票据会话
      // 凭 192-bit secret，不进类别预算（否则公网被刷锁时扫码配对也一起瘫掉）。
      if (isTicket
          ? (sourceKey != null &&
                _pinRateLimiter.isLockedOut(sourceKey, _now()))
          : _pinLockedOut(session.originClass, sourceKey)) {
        return _pairRateLimited();
      }
      final String? pinProof = body?['pinProof']?.toString();
      // 缺 proof 同样计一次失败：否则攻击者可用「开会话→空 proof」零成本探测锁定态
      // 之外的东西。
      final bool ok =
          pinProof != null &&
          pinProof.trim().isNotEmpty &&
          FushiPairingProtocol.verifyPinProof(
            pin: session.pin,
            clientNonce: session.clientNonce,
            hostNonce: session.hostNonce,
            submittedProof: pinProof,
          );
      if (!ok) {
        // 记一次来源级失败 + 类别级失败；任一因此进入锁定 → 429（限速），否则 401
        // （PIN 错 / 缺 proof，不再问 host、不弹窗）。
        final DateTime now = _now();
        final bool sourceLocked =
            sourceKey != null && _pinRateLimiter.recordFailure(sourceKey, now);
        final bool classLocked =
            !isTicket && _pinBudgets[session.originClass]!.recordFailure(now);
        if (sourceLocked || classLocked) return _pairRateLimited();
        return _pairUnauthorized();
      }
    }

    // 设备钥匙持有证明：签名绑定本会话（sessionId + 双 nonce + deviceId + 公钥）。没上报
    // 公钥 / 没签 / 签错 = 未证明——配对照常（配对本身的授权是 PIN / 票据 / 审批），只是
    // 拿不到「我的设备」资格。
    final String? deviceKeyFingerprint = _verifiedDeviceKeyFingerprint(
      session,
      body?['deviceProof']?.toString(),
    );
    // 只有设备钥匙证明过的会话才在审批里提供「这是我的设备」。
    final FushiPairOwnerDeviceGrant? ownerDeviceGrant =
        deviceKeyFingerprint != null ? session.ownerDeviceGrant : null;

    // TODO-1296 / BUG-592: pinRequired 会话的 host 审批已在 CREATE 阶段完成——会话能
    // 存在于 _pairSessions 即代表 host 当时已点允许（见 _handlePairV2），故此处不再二次
    // 弹窗，只凭 pinProof 校验通过即派 token（双重确认 = 早前的人工允许 + 此刻的 proof
    // 校验，两者仍缺一不可）。免 PIN 会话（pinRequired=false）没有 CREATE 阶段审批，仍在
    // 此弹审批（无 PIN 可显示，行为不变）。
    if (!session.pinRequired) {
      final bool approved = await approve(
        FushiPairRequest(
          deviceName: session.deviceName,
          remoteAddress: session.remoteAddress,
          pinVerified: true,
          pinRequired: false,
          clientDeviceId: session.clientDeviceId,
          ownerDeviceGrant: ownerDeviceGrant,
        ),
      );
      if (!approved) return _pairDenied('declined');
    }

    // TODO-961 M3：成功配对 → 清零该来源的 PIN 失败计数与锁定态（不株连未来尝试）。
    if (sourceKey != null) _pinRateLimiter.recordSuccess(sourceKey);
    // BUG-4280：本类别有 PIN 会话配对成功 → 类别预算的级数与计数清零。
    if (session.pinRequired && !isTicket) {
      _pinBudgets[session.originClass]!.recordSuccess();
    }
    // 一次性票据：配成一台就作废（二维码被别人再扫一次也没用）。
    if (session.ticketId != null && _pairTicket?.id == session.ticketId) {
      _pairTicket = null;
    }

    // TODO-961 M1b：per-peer token 派发。仅当 host 接线了落库回调（onPeerPaired）
    // **且** client 上报了稳定 deviceId 时，才生成本设备专属 token 并写库、回给该
    // client。任一缺失（纯协议单测无 DB / 旧 client 不上报 deviceId）则回退共享
    // [_token]——既有行为零变化、老设备继续可配对（Never break userspace）。
    final String issuedToken = await _issuePeerTokenOrFallback(
      session,
      ownerDevice: ownerDeviceGrant?.granted ?? false,
      deviceKeyFingerprint: deviceKeyFingerprint,
    );
    return jsonResponse(<String, dynamic>{
      'token': issuedToken,
      if (_securityContext != null && _hostFingerprint != null)
        'hostFingerprint': _hostFingerprint,
    });
  }

  /// confirm 成功后派发访问 token：有 [onPeerPaired] 回调且会话带 clientDeviceId
  /// 时生成 per-peer token、经回调落库并清 token 缓存（吊销/新增即时生效），返回该
  /// token；否则回退共享 [_token]（无 DB 接线 / 旧 client 无 deviceId 的兼容路径）。
  Future<String> _issuePeerTokenOrFallback(
    FushiPairSession session, {
    required bool ownerDevice,
    required String? deviceKeyFingerprint,
  }) async {
    final Future<void> Function(FushiPairedPeerRegistration)? persist =
        onPeerPaired;
    final String? peerId = session.clientDeviceId?.trim();
    if (persist == null || peerId == null || peerId.isEmpty) {
      return _token;
    }
    final String peerToken = FushiSyncServer.generateToken();
    await persist(
      FushiPairedPeerRegistration(
        peerId: peerId,
        token: peerToken,
        deviceName: session.deviceName,
        remoteAddress: session.remoteAddress,
        ownerDevice: ownerDevice && deviceKeyFingerprint != null,
        deviceKeyFingerprint: deviceKeyFingerprint,
      ),
    );
    // 新 token 立即受理：清缓存促下次 auth 从 provider 重载（含刚写入的这行）。
    invalidatePeerTokenCache();
    return peerToken;
  }

  /// 本会话的设备钥匙持有证明验签通过时返回公钥指纹，否则 null。
  String? _verifiedDeviceKeyFingerprint(
    FushiPairSession session,
    String? proof,
  ) {
    final String? pubkey = session.devicePubkey;
    final String? deviceId = session.clientDeviceId?.trim();
    if (pubkey == null || deviceId == null || deviceId.isEmpty) return null;
    if (proof == null || proof.trim().isEmpty) return null;
    final bool ok = verifyInterconnectPairDeviceProof(
      sessionId: session.sessionId,
      hostNonce: session.hostNonce,
      clientNonce: session.clientNonce,
      clientDeviceId: deviceId,
      devicePubkey: pubkey,
      proof: proof.trim(),
    );
    return ok ? interconnectDeviceKeyFingerprint(pubkey) : null;
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
    final Map<String, Object?>? subscriptions = await _subscriptions
        ?.capability();
    final Map<String, Object?>? assistant = await _assistant?.capability();
    return jsonResponse(<String, dynamic>{
      // 复习同步的长轮询通知（`GET /api/srs/changes`）。老 host 没有这一位，客户端只按定时同步。
      'srsChangesV1': true,
      if (mangaOcr != null) 'mangaOcr': mangaOcr,
      // 通用任务能力位：`jobs.kinds` + 每种 kind 的就绪信息；老 client 读不到也不崩。
      if (jobs != null) 'jobs': jobs,
      // `deleteFilesParam`：本路由的 DELETE 认 `?deleteFiles=`（BUG-3437）；老 host
      // 没有这个键，client 据此决定能不能让用户选「同时删除已下载文件」。
      if (downloads != null)
        'downloads': <String, Object?>{
          ...downloads,
          kHostDownloadDeleteFilesParamCapability: true,
        },
      if (subscriptions != null) 'subscriptions': subscriptions,
      if (assistant != null) 'assistant': assistant,
      // 查词 / 制卡 / 查词历史 / 游戏串流：这台 host 是否接了对应 service（老 host
      // 无这些字段，client 照旧以端点 404 判断）。只说「懂不懂这条路由」，不代表此刻
      // 一定成功——例如制卡还要 host 已登录 Anki、查词还要 host 装了词典。
      'lookup': <String, dynamic>{
        'dictionary': _remoteLookupService != null,
        'history': _historyService != null,
      },
      'mining': activeRemoteMiningService(_miningService) != null,
      'gameStream': _gameStreamService != null,
      // 远程更新 host（反馈 Pp8XPyve0N）：client 据此决定是否显示「主机版本」行。
      'hostUpdate': hostSelfUpdater != null,
      // 互联文件箱的同步根树列举（BUG-3743）：PROPFIND `Depth: infinity` 完整列出的
      // 层数。老 host 无此字段 → client 不发 infinity（老 host 会把它当 Depth 0、只回
      // 根自身，被误读成「远端没有任何书文件夹」），照旧逐本 Depth 1 列举。
      kInterconnectDavCapabilityGroup: <String, dynamic>{
        kInterconnectDavTreeListingLevelsField: kDavTreeListingMaxLevels,
      },
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
        // 互联作品图谱同步（`/api/library/media-links`）。老 host 无此字段 / false
        // → client 跳过作品图谱维度。
        'mediaLinks': _libraryService is MediaLinkSyncHost,
        // 弱网实时转码（`/streamurl?maxHeight=&maxBitrate=`）。老 host 无此字段 →
        // client 不显示画质档，行为与从前一致。字段随用户开关与本机 ffmpeg 可用性
        // 实时变化，不是启动时的快照；最终真相仍是 `/streamurl` 回的 `transcoded`。
        'videoTranscode': lib && _videoTranscodeEnabled,
        // 远端导入 / 重定时字幕「设为这一集的默认字幕」（`PUT .../subtitle` 带
        // `X-Fushi-Subtitle-Default: 1`，host 按自己的学习语言定后缀、旧 sidecar
        // 改名 `.fushi-bak` 让位）。老 host 无此字段 → client **不上传**：老 host
        // 不认那个 header，会走 live push 的旧路径按 client 报的后缀落盘，
        // `rename` 直接覆盖 host 上同名的旧字幕且不留备份（BUG-2728）。
        'videoSubtitleDefault': _libraryService is VideoSubtitleDefaultHost,
        // `DELETE .../subtitle?which=`（清字幕源 + 备份本视频 sidecar）与
        // `POST .../subtitle/backfill`（立即补字幕）。老 host 无此字段 → 404。
        'videoSubtitleClear': _libraryService is VideoSubtitleClearHost,
        // 远端原盘：整盘下载 + 流式原盘菜单共用的只读盘目录服务
        // （`/api/library/videos/<id>/disc` + `/api/library/disc/<token>/**`）。老 host
        // 无此字段 → client 的远端原盘按钮说明「对端版本过低」，不发请求。
        kDiscShareCapability: _libraryService is VideoDiscShareHost,
        // 互联远端片段导出（`GET .../clipvideo`，反馈 6nBmSBj_2W）。老 host 无此字段
        // → client 提示「对端版本过低」，不发请求。
        kVideoClipExportCapability: _libraryService is VideoClipExportHost,
        'videoSubtitleBackfill': lib && videoSubtitleBackfill != null,
        // 图形字幕整轨回传（`GET .../graphicsubtitle?embeddedStreamIndex=`）。老 host
        // 无此字段 / 没注入抽取实现 → false，client 不请求、时间表只靠边播边记。
        'videoGraphicSubtitleTrack':
            lib && graphicSubtitleTrackExporter != null,
        // TMDB 备选排序（`/api/library/metadata/episode-group*`）。
        'videoMetadataOrdering': _libraryService is VideoMetadataOrderingHost,
        'serviceConfig':
            _securityContext != null &&
            _libraryService is InterconnectServiceConfigHost,
        // 互联「配置文件」（Profile）双向搬运：与 serviceConfig 同门槛（必须 TLS）。
        // 能力位只说「这台 host 懂这个端点」，不代表此刻允许——端点还会再查一次
        // 用户开关，关着时返回 403，client 如实报错而不是当成不支持。
        'profileTransfer':
            _securityContext != null &&
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

  /// BUG-4280：PIN 会话是否因失败过多被拒——本来源类别的总预算锁定，或（来源可识别时）
  /// 本来源被 [_pinRateLimiter] 锁定。
  bool _pinLockedOut(FushiPairOriginClass originClass, String? sourceKey) {
    final DateTime now = _now();
    if (_pinBudgets[originClass]!.isLockedOut(now)) return true;
    return sourceKey != null && _pinRateLimiter.isLockedOut(sourceKey, now);
  }

  /// TODO-961 M1 / BUG-4280：为 [origin] 即将新建的会话腾位置；腾不出返回 false。
  ///
  /// 上限按来源类别分区（[_maxPairSessionsPerClass]），公网刷会话挤不掉局域网 / 隧道
  /// 的会话；可信来源键再限每来源 [_maxPairSessionsPerSource] 个，超了只淘汰它自己的。
  /// 类别满时淘汰该类别里会话最多的来源（null 键各自算一个来源）的最旧会话，所以单一
  /// 来源只能挤掉自己的。受保护会话（票据、人工批准过的 PIN 会话）永不淘汰；类别里
  /// 全是受保护会话仍满 → false（调用方回 429）。
  bool _enforcePairSessionCap(_RequestOrigin origin) {
    final FushiPairOriginClass cls = origin.originClass;
    final String? sourceKey = origin.sourceKey;
    bool evictable(FushiPairSession s) =>
        s.originClass == cls && !s.protectedFromEviction;

    // 1. 每来源限额：只对能区分真实来源的键做（回环未经可信代理、`p2p:?` 跳过——
    //    否则经本机反代进来的所有人共用一个名额）。
    if (origin.sourceKeyTrusted && sourceKey != null) {
      while (true) {
        final List<MapEntry<String, FushiPairSession>>
        mine = <MapEntry<String, FushiPairSession>>[
          for (final MapEntry<String, FushiPairSession> e
              in _pairSessions.entries)
            if (e.value.originClass == cls && e.value.sourceKey == sourceKey) e,
        ];
        if (mine.length < _maxPairSessionsPerSource) break;
        final MapEntry<String, FushiPairSession>? oldest = _oldestOf(
          mine.where(
            (MapEntry<String, FushiPairSession> e) => evictable(e.value),
          ),
        );
        if (oldest == null) break;
        _pairSessions.remove(oldest.key);
      }
    }

    // 2. 类别上限：淘汰会话最多的来源的最旧可淘汰会话，直到低于上限。
    while (true) {
      final List<MapEntry<String, FushiPairSession>> inClass =
          <MapEntry<String, FushiPairSession>>[
            for (final MapEntry<String, FushiPairSession> e
                in _pairSessions.entries)
              if (e.value.originClass == cls) e,
          ];
      if (inClass.length < _maxPairSessionsPerClass) return true;
      final List<MapEntry<String, FushiPairSession>> candidates =
          <MapEntry<String, FushiPairSession>>[
            for (final MapEntry<String, FushiPairSession> e in inClass)
              if (!e.value.protectedFromEviction) e,
          ];
      if (candidates.isEmpty) return false;
      // 每来源会话数（含受保护的：占得多就是占得多）；null 键不合并。
      final Map<String, int> perSource = <String, int>{};
      for (final MapEntry<String, FushiPairSession> e in inClass) {
        final String? k = e.value.sourceKey;
        if (k != null) perSource[k] = (perSource[k] ?? 0) + 1;
      }
      int weight(FushiPairSession s) =>
          s.sourceKey == null ? 1 : perSource[s.sourceKey]!;
      final int heaviest = candidates
          .map((MapEntry<String, FushiPairSession> e) => weight(e.value))
          .reduce((int a, int b) => a > b ? a : b);
      final MapEntry<String, FushiPairSession> victim = _oldestOf(
        candidates.where(
          (MapEntry<String, FushiPairSession> e) => weight(e.value) == heaviest,
        ),
      )!;
      _pairSessions.remove(victim.key);
    }
  }
}

/// [entries] 里 createdAt 最早的一项；为空时 null。
MapEntry<String, FushiPairSession>? _oldestOf(
  Iterable<MapEntry<String, FushiPairSession>> entries,
) {
  MapEntry<String, FushiPairSession>? oldest;
  for (final MapEntry<String, FushiPairSession> e in entries) {
    if (oldest == null || e.value.createdAt.isBefore(oldest.value.createdAt)) {
      oldest = e;
    }
  }
  return oldest;
}

// ── 本域私有的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到
//    宿主类的 static，故提到库顶层）。

/// TODO-961 M1（会话 TTL/上限，对照 audio/video token 的 prune 模式）：只发
/// pair/v2 却不 confirm 的攻击者会留下永久驻留会话（慢速 DoS）。每个会话
/// [_pairSessionTtl] 后过期；超过分区上限时先 prune 再按 [_enforcePairSessionCap]
/// 的规则淘汰（BUG-4280）。
/// TTL 与现有 host 60s 自动 deny（[FushiSyncServerController]）对齐：会话生命周期
/// 不应长于一次审批窗口（留 90s 余量覆盖审批弹窗 + 用户输 PIN）。
const Duration _pairSessionTtl = Duration(seconds: 90);

/// 每个来源类别（局域网 / 隧道 / 公网）最多同时挂起的配对会话数（BUG-4280）。
const int _maxPairSessionsPerClass = 32;

/// 每个可信来源键最多同时挂起的配对会话数（BUG-4280）。
const int _maxPairSessionsPerSource = 4;

/// 转发层会附带的来源头（BUG-4279）。带任一个就说明请求经过了反代 / 穿透 / CDN，
/// TCP 对端只是转发者，不能据它判局域网。
const List<String> _kForwardingHeaders = <String>[
  'x-forwarded-for',
  'forwarded',
  'x-real-ip',
  'cf-connecting-ip',
  'true-client-ip',
];

/// 一次配对请求的来源（BUG-4279）：类别（是否局域网）、展示串、限速来源键。
/// 由 [_classifyRequestOrigin] 一处算出，配对 v1 / v2 / 票据会话都只读它。
class _RequestOrigin {
  const _RequestOrigin({
    required this.originClass,
    required this.display,
    required this.sourceKey,
    required this.sourceKeyTrusted,
  });

  final FushiPairOriginClass originClass;

  bool get isLanPeer => originClass == FushiPairOriginClass.lan;

  /// 审批框 / 落库 lastSeenIp / 无头 pending 展示用。
  final String? display;

  /// 限速与会话分桶用的来源键（步骤 5 消费）；null = 无法识别。
  final String? sourceKey;

  /// [sourceKey] 能否区分不同的真实来源：P2P NodeId、非回环 TCP 对端、经可信代理
  /// 解析出的转发 IP 为 true；回环对端（未经可信代理解析）与 `p2p:?` 为 false。
  final bool sourceKeyTrusted;
}

/// 请求来源分类（BUG-4279）。判定顺序：
/// 1. P2P 区域 → `p2p`；**不读任何转发头**（隧道里的头全是对端自填的）。
/// 2. 拿不到 TCP 对端 → `public`。
/// 3. 带任一转发头 → `public`，不论对端是否可信——伪造这些头只会让请求方自己被要 PIN。
/// 4. 回环对端且 `!loopbackPeerIsLan`（无头端）→ `public`。
/// 5. 否则对端是私网地址 → `lan`，不是 → `public`。
///
/// [trustedProxies] 只影响 [_RequestOrigin.sourceKey] / [_RequestOrigin.display]：对端
/// 命中且带转发头时取 `X-Forwarded-For` / `Forwarded: for=` 的最后一跳作真实来源。
_RequestOrigin _classifyRequestOrigin(
  shelf.Request request, {
  required bool loopbackPeerIsLan,
  required FushiAddressRangeSet trustedProxies,
}) {
  if (request.context[kFushiRequestZone] == 'p2p') {
    final String? node = (request.context[kFushiP2pPeer] as String?)?.trim();
    final bool known = node != null && node.isNotEmpty;
    return _RequestOrigin(
      originClass: FushiPairOriginClass.p2p,
      // P2P 隧道进来的连接在 TCP 层恒为 127.0.0.1：原样上屏会让 host 审批框里的公网
      // 陌生人看起来像「本机」（审查问题 4）。如实标成隧道。
      display: kFushiP2pRemoteAddress,
      sourceKey: known ? 'p2p:$node' : 'p2p:?',
      sourceKeyTrusted: known,
    );
  }
  final Object? info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) {
    return const _RequestOrigin(
      originClass: FushiPairOriginClass.public,
      display: null,
      sourceKey: null,
      sourceKeyTrusted: false,
    );
  }
  final InternetAddress peer = _unmappedAddress(info.remoteAddress);
  final String peerText = peer.address;
  final bool peerIsLoopback = peer.isLoopback;
  final bool forwarded = _kForwardingHeaders.any(request.headers.containsKey);

  final FushiPairOriginClass originClass;
  if (forwarded) {
    originClass = FushiPairOriginClass.public;
  } else if (peerIsLoopback && !loopbackPeerIsLan) {
    originClass = FushiPairOriginClass.public;
  } else {
    originClass = FushiPairingProtocol.isPrivateLanAddress(peerText)
        ? FushiPairOriginClass.lan
        : FushiPairOriginClass.public;
  }

  if (forwarded && trustedProxies.contains(peer)) {
    final InternetAddress? client = _forwardedClientAddress(request.headers);
    if (client != null) {
      final InternetAddress real = _unmappedAddress(client);
      return _RequestOrigin(
        originClass: originClass,
        display: '${real.address} (via $peerText)',
        sourceKey: fushiRateKeyForAddress(real),
        sourceKeyTrusted: true,
      );
    }
  }
  return _RequestOrigin(
    originClass: originClass,
    display: forwarded ? '$peerText (proxied)' : peerText,
    sourceKey: fushiRateKeyForAddress(peer),
    sourceKeyTrusted: !peerIsLoopback,
  );
}

/// v4 映射的 v6 地址还原成 v4（来源地址的唯一规范化口径，见
/// [FushiPairingProtocol.unmapIPv4MappedAddress]）。
InternetAddress _unmappedAddress(InternetAddress address) {
  final List<int> raw = fushiUnmapIPv4MappedRaw(address.rawAddress);
  if (raw.length == address.rawAddress.length) return address;
  return InternetAddress.fromRawAddress(
    Uint8List.fromList(raw),
    type: InternetAddressType.IPv4,
  );
}

/// 可信代理附带的真实来源：`X-Forwarded-For` 的最后一个条目，没有时取 RFC 7239
/// `Forwarded` 最后一个 `for=`。取不到或解析不了 → null（按对端处理）。
InternetAddress? _forwardedClientAddress(Map<String, String> headers) {
  final String? xff = headers['x-forwarded-for'];
  if (xff != null && xff.trim().isNotEmpty) {
    return _parseForwardedNode(xff.split(',').last);
  }
  final String? fwd = headers['forwarded'];
  if (fwd == null) return null;
  String? last;
  for (final String element in fwd.split(',')) {
    for (final String pair in element.split(';')) {
      final int eq = pair.indexOf('=');
      if (eq < 0) continue;
      if (pair.substring(0, eq).trim().toLowerCase() == 'for') {
        last = pair.substring(eq + 1);
      }
    }
  }
  return last == null ? null : _parseForwardedNode(last);
}

/// 一跳节点值：去引号；`[v6]:port` 取方括号内；`v4:port` 去端口。
InternetAddress? _parseForwardedNode(String raw) {
  String v = raw.trim();
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    v = v.substring(1, v.length - 1).trim();
  }
  if (v.startsWith('[')) {
    final int close = v.indexOf(']');
    if (close < 0) return null;
    v = v.substring(1, close);
  } else if (':'.allMatches(v).length == 1) {
    v = v.substring(0, v.indexOf(':'));
  }
  return InternetAddress.tryParse(v);
}
