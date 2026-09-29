//! fushi_p2p —— 基于 iroh 的 TCP-over-P2P 隧道（dumbpipe 形态）的 C ABI。
//!
//! 一个句柄 = 一个 iroh `Endpoint` + 它自己的 tokio runtime。
//! - 主机：`fp2p_host_listen(port)` 接受 ALPN `fushi/tcp/1` 的连接，每条双向流
//!   → 连 `127.0.0.1:port`，双向泵字节（半关闭语义正确）。
//! - 客户端：`fp2p_client_forward(node)` 在 `127.0.0.1:0` 监听，每条本地 TCP
//!   → 在（缓存的、断了会重连的）iroh 连接上开一条新双向流。
//!
//! FFI 约定：
//! - 永不 panic 过边界（每个导出函数都包 `catch_unwind`）。
//! - 返回的 `char*` 一律由调用方用 `fp2p_string_free` 释放。
//! - 复杂返回值是 JSON：成功 `{"ok":true,...}`，失败 `{"ok":false,"error":"..."}`。
//! - `fp2p_endpoint_create` 失败返回 NULL，原因用 `fp2p_last_error()` 取（线程局部）。
//!
//! 主机侧资源上限（NodeId 不花钱就能生成，只按对端限等于没限，必须有全局上限）：
//! - 每条连接最多 [MAX_STREAMS_PER_CONN] 条并发双向流，由 QUIC 流控在协议层强制
//!   （对端根本开不出第 N+1 条，而不是开出来再被拒）；单向流一律为 0。
//! - 同一 NodeId 只保留最新的一条入站连接（客户端本就每个对端只缓存一条，断了才重拨）。
//! - 入站连接总数 ≤ [MAX_INCOMING_CONNS]，超出直接 refuse。
//! - 转发到本地的流总数 ≤ [MAX_HOST_STREAMS]，超出立刻 reset（快速失败，不排队）。
//!
//! 对端身份：主机把每条隧道流转发成一条到 `127.0.0.1:port` 的 TCP 连接，并登记
//! 「这条 TCP 连接的本地源端口 → 对端 NodeId」。Dart 侧 HTTP 服务器从连接信息里拿到
//! 对端端口（= 这个源端口），用 `fp2p_host_peer` 查出是哪个 NodeId——隧道请求的限流与
//! 审批据此按真实（密码学）身份区分，而不是全部挤成同一个 127.0.0.1。

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::net::SocketAddr;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::str::FromStr;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use iroh::endpoint::{presets, Connection, QuicTransportConfig, RecvStream, SendStream, VarInt};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, RelayUrl, SecretKey, TransportAddr};
use serde_json::{json, Value};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Runtime;
use tokio::sync::Semaphore;
use tokio::task::JoinHandle;

/// 隧道协议的 ALPN。改了就是不兼容的新协议，必须换版本号。
pub const ALPN: &[u8] = b"fushi/tcp/1";

/// 每条双向流开头由客户端写的 4 字节魔数。
///
/// QUIC 的流在发送方写出第一个字节之前对端根本看不见（`accept_bi` 不返回），
/// 服务端先说话的协议会因此永远卡住；dumbpipe 用同样的握手字节解决。
/// 顺带挡掉乱入的流。
const STREAM_MAGIC: &[u8; 4] = b"FTP1";

/// 泵字节的缓冲区（每方向）。
const PUMP_BUF: usize = 64 * 1024;

/// QUIC 应用错误码：泵出错时 reset/stop 流用。
const ERR_PUMP: u32 = 1;

/// QUIC 应用错误码：主机资源已满（流 reset / 连接关闭时用）。
const ERR_BUSY: u32 = 2;

/// QUIC 应用错误码：同一对端来了更新的连接，旧连接让位。
const ERR_SUPERSEDED: u32 = 3;

/// 每条连接的并发双向流上限。一次 HTTP 请求一条流；32 足够一个客户端并行拉列表 +
/// 封面 + 一路视频，同时把单连接最坏内存压在 32 × 流窗口。
pub const MAX_STREAMS_PER_CONN: u32 = 32;

/// 主机同时接受的入站连接上限（不同 NodeId）。
pub const MAX_INCOMING_CONNS: usize = 64;

/// 主机同时转发到本地端口的流总数上限。
pub const MAX_HOST_STREAMS: usize = 256;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn set_last_error(msg: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = Some(msg));
}

// ---------------------------------------------------------------------------
// 核心状态
// ---------------------------------------------------------------------------

/// 一个客户端转发口。
struct Forward {
    task: JoinHandle<()>,
}

struct Shared {
    endpoint: Endpoint,
    forward_port: AtomicU16,
    /// 调用方给的地址提示（直连地址 / 中继），拨号时用。
    hints: Mutex<HashMap<EndpointId, EndpointAddr>>,
    /// 出站连接缓存。只用同步锁、从不跨 await 持有，FFI 线程读它不会被拨号卡住。
    conns: Mutex<HashMap<EndpointId, Connection>>,
    /// 每个远端一把拨号锁：并发的首批本地连接只拨一次号。
    dial_locks: Mutex<HashMap<EndpointId, Arc<tokio::sync::Mutex<()>>>>,
    /// 入站连接（主机侧），给 `fp2p_conn_status` 查对端路径用；同一 NodeId 只留最新一条。
    incoming: Mutex<HashMap<EndpointId, Connection>>,
    /// 主机转发流的全局配额（[MAX_HOST_STREAMS]）。
    host_streams: Arc<Semaphore>,
    /// 转发到本地的 TCP 连接的本地源端口 → 对端 NodeId（见模块文档「对端身份」）。
    host_peers: Mutex<HashMap<u16, EndpointId>>,
}

/// 登记一条「源端口 → NodeId」，析构时撤销——流无论正常结束、出错还是被取消都不留残项。
struct HostPeerEntry<'a> {
    shared: &'a Shared,
    port: u16,
}

impl Drop for HostPeerEntry<'_> {
    fn drop(&mut self) {
        self.shared.host_peers.lock().unwrap().remove(&self.port);
    }
}

pub struct P2p {
    rt: Runtime,
    shared: Arc<Shared>,
    host_task: Mutex<Option<JoinHandle<()>>>,
    forwards: Mutex<HashMap<u16, Forward>>,
}

fn build_runtime() -> Result<Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("fushi-p2p")
        .enable_all()
        .build()
        .context("tokio runtime")
}

fn parse_relay_mode(relay_urls: &[String]) -> Result<RelayMode> {
    if relay_urls.is_empty() {
        return Ok(RelayMode::Default);
    }
    let map = RelayMap::try_from_iter(relay_urls.iter().map(String::as_str))
        .map_err(|e| anyhow!("invalid relay url: {e}"))?;
    Ok(RelayMode::Custom(map))
}

impl P2p {
    fn create(secret_hex: Option<&str>, relay_urls: &[String]) -> Result<P2p> {
        let secret = match secret_hex {
            Some(s) if !s.trim().is_empty() => {
                SecretKey::from_str(s.trim()).map_err(|e| anyhow!("invalid secret key: {e}"))?
            }
            _ => SecretKey::generate(),
        };
        let relay_mode = parse_relay_mode(relay_urls)?;
        let rt = build_runtime()?;
        let transport = QuicTransportConfig::builder()
            .max_concurrent_bidi_streams(VarInt::from_u32(MAX_STREAMS_PER_CONN))
            .max_concurrent_uni_streams(VarInt::from_u32(0))
            .build();
        let endpoint = rt.block_on(async {
            let builder = Endpoint::builder(presets::N0)
                .secret_key(secret)
                .relay_mode(relay_mode)
                .transport_config(transport);
            #[cfg(feature = "dht")]
            let builder = builder
                .address_lookup(iroh_mainline_address_lookup::DhtAddressLookup::builder());
            builder.bind().await.map_err(|e| anyhow!("bind endpoint: {e}"))
        })?;
        let shared = Arc::new(Shared {
            endpoint,
            forward_port: AtomicU16::new(0),
            hints: Mutex::new(HashMap::new()),
            conns: Mutex::new(HashMap::new()),
            dial_locks: Mutex::new(HashMap::new()),
            incoming: Mutex::new(HashMap::new()),
            host_streams: Arc::new(Semaphore::new(MAX_HOST_STREAMS)),
            host_peers: Mutex::new(HashMap::new()),
        });
        Ok(P2p {
            rt,
            shared,
            host_task: Mutex::new(None),
            forwards: Mutex::new(HashMap::new()),
        })
    }

    fn info(&self) -> Value {
        let ep = &self.shared.endpoint;
        let addr = ep.addr();
        let relay: Option<String> = addr.relay_urls().next().map(|u| u.to_string());
        let direct: Vec<String> = addr.ip_addrs().map(|a| a.to_string()).collect();
        json!({
            "ok": true,
            "nodeId": ep.id().to_string(),
            "secretKeyHex": hex::encode(ep.secret_key().to_bytes()),
            "relayUrl": relay,
            "directAddrs": direct,
        })
    }

    fn host_listen(&self, port: u16) -> Result<()> {
        self.shared.forward_port.store(port, Ordering::SeqCst);
        if port == 0 {
            self.shared.endpoint.set_alpns(Vec::new());
            return Ok(());
        }
        self.shared.endpoint.set_alpns(vec![ALPN.to_vec()]);
        let mut task = self.host_task.lock().unwrap();
        if task.is_none() {
            let shared = self.shared.clone();
            *task = Some(self.rt.spawn(host_accept_loop(shared)));
        }
        Ok(())
    }

    fn client_forward(&self, node: &str, hint: Option<&Value>) -> Result<u16> {
        let id = EndpointId::from_str(node.trim()).map_err(|e| anyhow!("invalid node id: {e}"))?;
        let addr = match hint {
            Some(h) => Some(parse_addr_hint(id, h)?),
            None => None,
        };
        if let Some(addr) = addr {
            // 新提示覆盖旧提示；已建好的连接不动（仍可用就没理由断）。
            self.shared.hints.lock().unwrap().insert(id, addr);
        }
        let listener = self
            .rt
            .block_on(TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0))))
            .context("bind local forward port")?;
        let port = listener.local_addr()?.port();
        let shared = self.shared.clone();
        let task = self.rt.spawn(client_accept_loop(shared, listener, id));
        self.forwards.lock().unwrap().insert(port, Forward { task });
        Ok(port)
    }

    fn client_forward_stop(&self, port: u16) -> bool {
        match self.forwards.lock().unwrap().remove(&port) {
            Some(f) => {
                f.task.abort();
                // 等取消真正落地：accept 循环 future 被析构 = TcpListener 已关，
                // 返回后本地端口立刻不再接受连接（已建立的流是独立任务，不受影响）。
                let _ = self.rt.block_on(f.task);
                true
            }
            None => false,
        }
    }

    fn conn_status(&self, node: &str) -> Result<Value> {
        let id = EndpointId::from_str(node.trim()).map_err(|e| anyhow!("invalid node id: {e}"))?;
        let outgoing: Option<Connection> = self.shared.conns.lock().unwrap().get(&id).cloned();
        let conn = outgoing
            .filter(|c| c.close_reason().is_none())
            .or_else(|| {
                self.shared
                    .incoming
                    .lock()
                    .unwrap()
                    .get(&id)
                    .filter(|c| c.close_reason().is_none())
                    .cloned()
            });
        Ok(match conn {
            Some(c) => path_status(&c),
            None => json!({
                "ok": true, "connected": false, "path": "none", "rttMs": null,
                "directPaths": 0, "relayPaths": 0,
            }),
        })
    }

    /// 主机侧：本地源端口 [port] 的转发连接属于哪个对端。
    fn host_peer(&self, port: u16) -> Option<EndpointId> {
        self.shared.host_peers.lock().unwrap().get(&port).copied()
    }

    fn close(self) {
        for (_, f) in self.forwards.lock().unwrap().drain() {
            f.task.abort();
        }
        if let Some(t) = self.host_task.lock().unwrap().take() {
            t.abort();
        }
        let ep = self.shared.endpoint.clone();
        // endpoint.close 会优雅地关掉所有连接；给个上限，防止网络卡死把调用线程挂住。
        // 实测（Windows，同进程对端）：有过连接的端点 close 要 0.8~2.1 s，全耗在
        // iroh 自己的 Endpoint::close 里；空闲端点 ~10 ms。runtime shutdown < 1 ms。
        let _ = self
            .rt
            .block_on(async { tokio::time::timeout(Duration::from_secs(3), ep.close()).await });
        self.rt.shutdown_timeout(Duration::from_secs(1));
    }
}

impl Shared {
    /// 缓存里仍活着、且不是 `dead`（调用方刚发现已死的那条）的连接。
    fn cached(&self, id: &EndpointId, dead: Option<usize>) -> Option<Connection> {
        self.conns
            .lock()
            .unwrap()
            .get(id)
            .filter(|c| c.close_reason().is_none() && Some(c.stable_id()) != dead)
            .cloned()
    }

    /// 取到 `id` 的可用连接：缓存命中且未关闭就复用，否则拨号。
    /// `dead` = 调用方在这条连接上开流失败，要求换新的（别的任务已换过就直接用它的）。
    async fn connection(&self, id: EndpointId, dead: Option<usize>) -> Result<Connection> {
        if let Some(c) = self.cached(&id, dead) {
            return Ok(c);
        }
        let lock = self.dial_locks.lock().unwrap().entry(id).or_default().clone();
        let _dialing = lock.lock().await;
        // 等锁期间别的任务可能已经拨通了。
        if let Some(c) = self.cached(&id, dead) {
            return Ok(c);
        }
        let target: EndpointAddr = self
            .hints
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .unwrap_or_else(|| EndpointAddr::new(id));
        let conn = self
            .endpoint
            .connect(target, ALPN)
            .await
            .map_err(|e| anyhow!("connect {}: {e}", id.fmt_short()))?;
        self.conns.lock().unwrap().insert(id, conn.clone());
        Ok(conn)
    }
}

/// `{"directAddrs":["1.2.3.4:5"],"relayUrl":"https://..."}` → EndpointAddr。
fn parse_addr_hint(id: EndpointId, hint: &Value) -> Result<EndpointAddr> {
    let mut addrs: Vec<TransportAddr> = Vec::new();
    if let Some(list) = hint.get("directAddrs").and_then(Value::as_array) {
        for v in list {
            let s = v.as_str().ok_or_else(|| anyhow!("directAddrs must be strings"))?;
            let sa = SocketAddr::from_str(s).map_err(|e| anyhow!("bad direct addr {s}: {e}"))?;
            addrs.push(TransportAddr::Ip(sa));
        }
    }
    if let Some(r) = hint.get("relayUrl").and_then(Value::as_str) {
        if !r.is_empty() {
            let url = RelayUrl::from_str(r).map_err(|e| anyhow!("bad relay url {r}: {e}"))?;
            addrs.push(TransportAddr::Relay(url));
        }
    }
    Ok(EndpointAddr::from_parts(id, addrs))
}

fn path_status(c: &Connection) -> Value {
    let paths = c.paths();
    let mut direct = 0u32;
    let mut relay = 0u32;
    let mut selected: Option<(bool, Duration)> = None;
    for p in paths.iter() {
        if p.is_ip() {
            direct += 1;
        } else if p.is_relay() {
            relay += 1;
        }
        if p.is_selected() {
            selected = Some((p.is_ip(), p.rtt()));
        }
    }
    let path = match selected {
        Some((true, _)) => "direct",
        Some((false, _)) => "relay",
        None if direct > 0 && relay > 0 => "mixed",
        None if direct > 0 => "direct",
        None if relay > 0 => "relay",
        None => "none",
    };
    let rtt = selected
        .map(|(_, r)| r)
        .or_else(|| paths.iter().map(|p| p.rtt()).min())
        .map(|d| d.as_secs_f64() * 1000.0);
    json!({
        "ok": true, "connected": true, "path": path, "rttMs": rtt,
        "directPaths": direct, "relayPaths": relay,
    })
}

// ---------------------------------------------------------------------------
// 主机侧
// ---------------------------------------------------------------------------

async fn host_accept_loop(shared: Arc<Shared>) {
    while let Some(incoming) = shared.endpoint.accept().await {
        // 握手前就拒：连接数封顶，握手本身也要花 CPU。已登记的连接才计数，握手中的
        // 不计——最坏多出一批并发握手，由 QUIC 自己的握手限流兜住。
        if shared.incoming.lock().unwrap().len() >= MAX_INCOMING_CONNS {
            incoming.refuse();
            continue;
        }
        let shared = shared.clone();
        tokio::spawn(async move {
            let Ok(accepting) = incoming.accept() else { return };
            let Ok(conn) = accepting.await else { return };
            host_serve_connection(shared, conn).await;
        });
    }
}

async fn host_serve_connection(shared: Arc<Shared>, conn: Connection) {
    let remote = conn.remote_id();
    let superseded = shared.incoming.lock().unwrap().insert(remote, conn.clone());
    if let Some(old) = superseded.filter(|c| c.stable_id() != conn.stable_id()) {
        // 同一对端只留最新一条：客户端只在旧连接死掉后才重拨，旧的留着只会占配额。
        old.close(VarInt::from_u32(ERR_SUPERSEDED), b"superseded");
    }
    loop {
        match conn.accept_bi().await {
            Ok((send, recv)) => {
                let shared = shared.clone();
                tokio::spawn(async move {
                    let _ = host_serve_stream(&shared, remote, send, recv).await;
                });
            }
            Err(_) => break, // 连接关闭。
        }
    }
    let mut map = shared.incoming.lock().unwrap();
    if map.get(&remote).is_some_and(|c| c.stable_id() == conn.stable_id()) {
        map.remove(&remote);
    }
}

async fn host_serve_stream(
    shared: &Shared,
    remote: EndpointId,
    mut send: SendStream,
    mut recv: RecvStream,
) -> Result<()> {
    let mut magic = [0u8; 4];
    if recv.read_exact(&mut magic).await.is_err() || &magic != STREAM_MAGIC {
        let _ = send.reset(VarInt::from_u32(ERR_PUMP));
        let _ = recv.stop(VarInt::from_u32(ERR_PUMP));
        bail!("bad stream magic");
    }
    let Ok(_permit) = shared.host_streams.clone().try_acquire_owned() else {
        let _ = send.reset(VarInt::from_u32(ERR_BUSY));
        let _ = recv.stop(VarInt::from_u32(ERR_BUSY));
        bail!("host stream quota exhausted");
    };
    let port = shared.forward_port.load(Ordering::SeqCst);
    let tcp = if port == 0 {
        None
    } else {
        TcpStream::connect(SocketAddr::from(([127, 0, 0, 1], port))).await.ok()
    };
    let Some(tcp) = tcp else {
        let _ = send.reset(VarInt::from_u32(ERR_PUMP));
        let _ = recv.stop(VarInt::from_u32(ERR_PUMP));
        bail!("forward target unavailable");
    };
    // 在泵第一个字节之前登记：本地 HTTP 服务器要读到请求字节才会处理请求，那时
    // 这条映射一定已经在了。
    let local_port = tcp.local_addr()?.port();
    shared.host_peers.lock().unwrap().insert(local_port, remote);
    let _entry = HostPeerEntry { shared, port: local_port };
    pump(tcp, send, recv).await
}

// ---------------------------------------------------------------------------
// 客户端侧
// ---------------------------------------------------------------------------

async fn client_accept_loop(shared: Arc<Shared>, listener: TcpListener, id: EndpointId) {
    loop {
        let tcp = match listener.accept().await {
            Ok((tcp, _)) => tcp,
            // accept 失败多半是 fd 耗尽（EMFILE）之类的暂态；立刻重试会空转吃满 CPU。
            Err(_) => {
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
        };
        let shared = shared.clone();
        tokio::spawn(async move {
            let _ = client_serve_tcp(&shared, tcp, id).await;
        });
    }
}

async fn client_open_stream(shared: &Shared, id: EndpointId) -> Result<(SendStream, RecvStream)> {
    let conn = shared.connection(id, None).await?;
    match conn.open_bi().await {
        Ok(s) => Ok(s),
        // 缓存的连接已死（对端重启/网络切换）：换一条新连接，只换一次。
        Err(_) => {
            let conn = shared.connection(id, Some(conn.stable_id())).await?;
            conn.open_bi().await.map_err(|e| anyhow!("open stream: {e}"))
        }
    }
}

async fn client_serve_tcp(shared: &Shared, tcp: TcpStream, id: EndpointId) -> Result<()> {
    let (mut send, recv) = client_open_stream(shared, id).await?;
    send.write_all(STREAM_MAGIC).await?;
    pump(tcp, send, recv).await
}

// ---------------------------------------------------------------------------
// 双向泵
// ---------------------------------------------------------------------------

/// TCP ⇄ QUIC 双向流。任一方向读到 EOF 就把对侧写端半关闭，两侧都结束才返回；
/// 任一方向出错立刻 reset/stop 流并丢掉 TCP（RST 给本地一侧）。
async fn pump(tcp: TcpStream, mut send: SendStream, mut recv: RecvStream) -> Result<()> {
    let _ = tcp.set_nodelay(true);
    let (tcp_r, mut tcp_w) = tcp.into_split();
    let res: std::io::Result<((), ())> = {
        let up = async {
            let mut r = BufReader::with_capacity(PUMP_BUF, tcp_r);
            tokio::io::copy_buf(&mut r, &mut send).await?;
            send.finish().map_err(std::io::Error::other)?;
            Ok::<(), std::io::Error>(())
        };
        let down = async {
            let mut r = BufReader::with_capacity(PUMP_BUF, &mut recv);
            tokio::io::copy_buf(&mut r, &mut tcp_w).await?;
            tcp_w.shutdown().await?;
            Ok::<(), std::io::Error>(())
        };
        tokio::try_join!(up, down)
    };
    match res {
        Ok(_) => {
            // 等对端确认收完再让 SendStream 析构，否则连接关闭时尾巴可能丢。
            let _ = send.stopped().await;
            Ok(())
        }
        Err(e) => {
            let _ = send.reset(VarInt::from_u32(ERR_PUMP));
            let _ = recv.stop(VarInt::from_u32(ERR_PUMP));
            Err(e.into())
        }
    }
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

fn into_c_string(s: String) -> *mut c_char {
    // JSON 里不会有内部 NUL（serde_json 会转义 \u0000）；兜底去掉以免 panic。
    CString::new(s.replace('\0', "")).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

fn json_out(v: Value) -> *mut c_char {
    into_c_string(v.to_string())
}

fn json_err(msg: impl std::fmt::Display) -> *mut c_char {
    json_out(json!({"ok": false, "error": msg.to_string()}))
}

fn panic_message(p: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        format!("panic: {s}")
    } else if let Some(s) = p.downcast_ref::<String>() {
        format!("panic: {s}")
    } else {
        "panic".to_string()
    }
}

/// 把 `f` 的结果 JSON 化；panic 与 Err 都落成 `{"ok":false}`。
fn guard_json(f: impl FnOnce() -> Result<Value>) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => json_out(v),
        Ok(Err(e)) => json_err(format!("{e:#}")),
        Err(p) => json_err(panic_message(p)),
    }
}

unsafe fn opt_str<'a>(p: *const c_char) -> Result<Option<&'a str>> {
    if p.is_null() {
        return Ok(None);
    }
    CStr::from_ptr(p).to_str().map(Some).map_err(|_| anyhow!("argument is not valid UTF-8"))
}

unsafe fn handle<'a>(h: *mut P2p) -> Result<&'a P2p> {
    h.as_ref().ok_or_else(|| anyhow!("null endpoint handle"))
}

/// 库版本（静态字符串，不要 free）。
#[no_mangle]
pub extern "C" fn fp2p_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// 释放本库返回的任意 `char*`。NULL 为 no-op。
#[no_mangle]
pub unsafe extern "C" fn fp2p_string_free(s: *mut c_char) {
    if !s.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(s))));
    }
}

/// 本线程最近一次 `fp2p_endpoint_create` 的失败原因；无则 NULL。调用方 free。
#[no_mangle]
pub extern "C" fn fp2p_last_error() -> *mut c_char {
    catch_unwind(|| LAST_ERROR.with(|e| e.borrow().clone()))
        .ok()
        .flatten()
        .map(into_c_string)
        .unwrap_or(std::ptr::null_mut())
}

/// 创建端点。`secret_key_hex` NULL/空 = 新生成；`relay_urls_json` NULL/空/`[]` =
/// iroh 默认 n0 中继，否则为 URL 字符串数组（自建 iroh-relay）。失败返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn fp2p_endpoint_create(
    secret_key_hex: *const c_char,
    relay_urls_json: *const c_char,
) -> *mut P2p {
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<P2p> {
        let secret = opt_str(secret_key_hex)?;
        let relays: Vec<String> = match opt_str(relay_urls_json)? {
            Some(s) if !s.trim().is_empty() => {
                serde_json::from_str(s).context("relay_urls_json must be a JSON string array")?
            }
            _ => Vec::new(),
        };
        P2p::create(secret, &relays)
    }));
    match r {
        Ok(Ok(p)) => Box::into_raw(Box::new(p)),
        Ok(Err(e)) => {
            set_last_error(format!("{e:#}"));
            std::ptr::null_mut()
        }
        Err(p) => {
            set_last_error(panic_message(p));
            std::ptr::null_mut()
        }
    }
}

/// `{"ok":true,"nodeId","secretKeyHex","relayUrl","directAddrs":[...]}`。
#[no_mangle]
pub unsafe extern "C" fn fp2p_endpoint_info(h: *mut P2p) -> *mut c_char {
    guard_json(|| Ok(handle(h)?.info()))
}

/// 等端点连上 home relay（最多 `timeout_ms`）。返回同 `fp2p_endpoint_info`，
/// 外加 `"online":bool`。
#[no_mangle]
pub unsafe extern "C" fn fp2p_endpoint_online(h: *mut P2p, timeout_ms: u32) -> *mut c_char {
    guard_json(|| {
        let p = handle(h)?;
        let ep = p.shared.endpoint.clone();
        let online = p.rt.block_on(async {
            tokio::time::timeout(Duration::from_millis(timeout_ms as u64), ep.online()).await.is_ok()
        });
        let mut v = p.info();
        v["online"] = json!(online);
        Ok(v)
    })
}

/// 开始（或改）主机转发：进来的流 → `127.0.0.1:forward_port`。`0` = 停止接受。
#[no_mangle]
pub unsafe extern "C" fn fp2p_host_listen(h: *mut P2p, forward_port: u16) -> *mut c_char {
    guard_json(|| {
        handle(h)?.host_listen(forward_port)?;
        Ok(json!({"ok": true}))
    })
}

/// 客户端转发：`127.0.0.1:<port>` → `node_id`。`addr_hint_json` 可 NULL，
/// 否则 `{"directAddrs":["ip:port",...],"relayUrl":"https://..."}`（不经发现直拨）。
/// 返回 `{"ok":true,"port":N}`。
#[no_mangle]
pub unsafe extern "C" fn fp2p_client_forward(
    h: *mut P2p,
    node_id: *const c_char,
    addr_hint_json: *const c_char,
) -> *mut c_char {
    guard_json(|| {
        let p = handle(h)?;
        let node = opt_str(node_id)?.ok_or_else(|| anyhow!("node_id is null"))?;
        let hint: Option<Value> = match opt_str(addr_hint_json)? {
            Some(s) if !s.trim().is_empty() => Some(serde_json::from_str(s).context("addr_hint_json")?),
            _ => None,
        };
        let port = p.client_forward(node, hint.as_ref())?;
        Ok(json!({"ok": true, "port": port}))
    })
}

/// 停掉一个客户端转发口。返回 `{"ok":true,"stopped":bool}`。
#[no_mangle]
pub unsafe extern "C" fn fp2p_client_forward_stop(h: *mut P2p, port: u16) -> *mut c_char {
    guard_json(|| Ok(json!({"ok": true, "stopped": handle(h)?.client_forward_stop(port)})))
}

/// `{"ok":true,"connected":bool,"path":"direct"|"relay"|"mixed"|"none","rttMs":f|null,
/// "directPaths":n,"relayPaths":n}`。出站连接优先，其次入站连接。
#[no_mangle]
pub unsafe extern "C" fn fp2p_conn_status(h: *mut P2p, node_id: *const c_char) -> *mut c_char {
    guard_json(|| {
        let node = opt_str(node_id)?.ok_or_else(|| anyhow!("node_id is null"))?;
        handle(h)?.conn_status(node)
    })
}

/// 主机侧：本地源端口 `port` 的那条转发 TCP 连接属于哪个对端。
/// 返回 `{"ok":true,"nodeId":"<hex>"|null}`；null = 不是（或已不是）隧道转发连接。
#[no_mangle]
pub unsafe extern "C" fn fp2p_host_peer(h: *mut P2p, port: u16) -> *mut c_char {
    guard_json(|| {
        let peer = handle(h)?.host_peer(port).map(|id| id.to_string());
        Ok(json!({"ok": true, "nodeId": peer}))
    })
}

/// 关闭并释放端点。之后句柄失效。NULL 为 no-op。
#[no_mangle]
pub unsafe extern "C" fn fp2p_endpoint_close(h: *mut P2p) {
    if h.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| Box::from_raw(h).close()));
}
