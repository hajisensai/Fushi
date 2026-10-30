//! 插件实例：一个 QuickJS 运行时 + 已校验的包内源码 + 网络授权。
//!
//! **步进式驱动**（不在 FFI 上回调 Dart）：宿主每次 [Instance::step] 交来一批操作——
//! 发起能力调用（`invoke`）或交回宿主调用的结果（`complete`）——Rust 执行 JS 直到没有可运行的
//! 任务，然后把「已结束的能力调用」「新发出的宿主调用（http / storage）」「日志」一次性交回。
//! 插件代码 `await fushi.http.request(...)` 时 JS 停在 Promise 上，等宿主做完网络请求、下一次
//! `step` 交回结果再继续。一次用户操作通常只要 2～4 次 FFI 调用。
//!
//! 资源上限：内存 64 MiB、JS 栈 256 KiB、单步 CPU 预算（默认 2 s，超时整个实例作废，宿主重建）。

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use rquickjs::{Context, Ctx, Exception, Function, Runtime, TypedArray, Value};
use serde::Deserialize;
use serde_json::{json, Value as Json};

use crate::plugin::jsapi;
use crate::plugin::manifest::{Manifest, HOST_API_VERSION};
use crate::plugin::package::VerifiedPackage;
use crate::plugin::policy::{Policy, Purpose};

const PRELUDE: &str = include_str!("prelude.js");
const MEMORY_LIMIT: usize = 64 * 1024 * 1024;
/// 留足余量：实例在 Dart 后台 isolate 的线程上执行，线程栈可能只有 1 MiB。
const STACK_LIMIT: usize = 256 * 1024;
const MAX_LOGS_PER_STEP: usize = 200;
const MAX_LOG_CHARS: usize = 4000;
const MAX_HEADERS: usize = 64;
const MAX_HEADER_BYTES: usize = 8 * 1024;
const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;
const MAX_STORAGE_KEY: usize = 256;
const MAX_STORAGE_VALUE: usize = 1024 * 1024;
const MAX_RESULT_BYTES: usize = 8 * 1024 * 1024;
/// 同时在途的宿主调用上限（宿主那边每条都是一次网络 / 磁盘操作与一份缓冲）。
pub(crate) const MAX_INFLIGHT_CALLS: usize = 32;
/// 单次 step 内新发起的宿主调用上限。
pub(crate) const MAX_CALLS_PER_STEP: usize = 64;
/// 单次 step 内交给宿主的调用参数总字节上限（请求体等）。
pub(crate) const MAX_OUT_BYTES_PER_STEP: usize = 16 * 1024 * 1024;
/// 单次 step 交回的能力结果条数与总字节上限。
pub(crate) const MAX_SETTLED_PER_STEP: usize = 256;
pub(crate) const MAX_SETTLED_BYTES_PER_STEP: usize = 16 * 1024 * 1024;
/// 宿主调用的超时下限 / 上限（毫秒）；插件不给就用默认。
const HTTP_TIMEOUT_DEFAULT: u64 = 20_000;
const HTTP_TIMEOUT_MAX: u64 = 60_000;

/// JS 侧经原生函数写进来、step 结束时取走的东西。
#[derive(Default)]
pub(crate) struct Outbox {
    next_call: u64,
    pub(crate) calls: Vec<Json>,
    pub(crate) settled: Vec<Json>,
    pub(crate) logs: Vec<Json>,
    /// 本 step 交给宿主的二进制数据（请求体）：调用参数里只放 `{"off","len"}` 引用。
    out_blob: Vec<u8>,
    logs_dropped: usize,
    /// 已发给宿主、尚未 complete 的宿主调用 id。
    pending_calls: std::collections::BTreeSet<u64>,
    /// 宿主发起、尚未 settle 的能力调用 id（插件自己调 `__fushi_invoke` 伪造的 settle 不收）。
    pending_invs: std::collections::BTreeSet<u64>,
    step_calls: usize,
    step_out_bytes: usize,
    settled_bytes: usize,
    /// 超限：本 step 结束时转成 fatal（实例作废，宿主丢弃后按需重建）。
    abort: Option<String>,
}

impl Outbox {
    fn begin_step(&mut self) {
        self.step_calls = 0;
        self.step_out_bytes = 0;
        self.settled_bytes = 0;
    }

    fn fail(&mut self, msg: String) -> String {
        if self.abort.is_none() {
            self.abort = Some(msg.clone());
        }
        msg
    }

    pub(crate) fn log(&mut self, level: &str, msg: &str) {
        if self.logs.len() >= MAX_LOGS_PER_STEP {
            self.logs_dropped += 1;
            return;
        }
        let msg: String = msg.chars().take(MAX_LOG_CHARS).collect();
        self.logs.push(json!({ "level": level, "message": msg }));
    }
}

/// 宿主调用的核对：插件发出的每个 http / storage 请求在这里按清单把关，越权的直接在 JS 里抛错，
/// 不会到达宿主。
pub(crate) struct Gate {
    pub(crate) manifest: Manifest,
    pub(crate) policy: Policy,
    pub(crate) sources: BTreeMap<String, String>,
    pub(crate) outbox: Mutex<Outbox>,
}

impl Gate {
    /// 核对并登记一次宿主调用，返回调用 id。[body] 是请求体原始字节（只有 http 收），不经
    /// base64：随 step 输出的二进制区交给宿主，参数里只留 `body: {off, len}`。
    pub(crate) fn host_call(&self, op: &str, args_json: &str, body: Option<Vec<u8>>) -> Result<u64, String> {
        let args: Json =
            serde_json::from_str(args_json).map_err(|e| format!("宿主调用参数不是 JSON：{e}"))?;
        if body.is_some() && op != "http" {
            return Err(format!("宿主调用 {op} 不收二进制数据"));
        }
        if body.as_ref().is_some_and(|b| b.len() > MAX_BODY_BYTES) {
            return Err("请求体超过 4 MiB".into());
        }
        let mut normalized = match op {
            "http" => self.check_http(&args)?,
            "storage.get" | "storage.set" | "storage.remove" => self.check_storage(op, &args)?,
            "credentials.get" | "credentials.set" | "credentials.remove" => {
                self.check_credentials(op, &args)?
            }
            _ => return Err(format!("未知宿主调用 {op}")),
        };
        let size = normalized.to_string().len() + body.as_ref().map_or(0, Vec::len);
        let mut out = self.outbox.lock().unwrap();
        if out.pending_calls.len() >= MAX_INFLIGHT_CALLS {
            return Err(out.fail(format!("在途宿主调用超过 {MAX_INFLIGHT_CALLS} 个，插件已终止")));
        }
        if out.step_calls >= MAX_CALLS_PER_STEP {
            return Err(out.fail(format!("单步宿主调用超过 {MAX_CALLS_PER_STEP} 个，插件已终止")));
        }
        if out.step_out_bytes + size > MAX_OUT_BYTES_PER_STEP {
            return Err(out.fail("单步宿主调用参数超过 16 MiB，插件已终止".into()));
        }
        out.step_calls += 1;
        out.step_out_bytes += size;
        if let Some(b) = body {
            normalized["body"] = json!({ "off": out.out_blob.len(), "len": b.len() });
            out.out_blob.extend_from_slice(&b);
        }
        out.next_call += 1;
        let id = out.next_call;
        out.pending_calls.insert(id);
        out.calls.push(json!({ "id": id, "op": op, "args": normalized }));
        Ok(id)
    }

    fn check_http(&self, args: &Json) -> Result<Json, String> {
        if !self.manifest.has_permission("network") {
            return Err("插件没有 network 权限".into());
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Req {
            url: String,
            method: String,
            #[serde(default)]
            headers: BTreeMap<String, String>,
            #[serde(default)]
            timeout_ms: u64,
        }
        let req: Req =
            serde_json::from_value(args.clone()).map_err(|e| format!("http 参数不合法：{e}"))?;
        self.policy.check_method(&req.method)?;
        let url = self.policy.check_url(&req.url, Purpose::Request)?;
        if req.headers.len() > MAX_HEADERS {
            return Err("请求头过多".into());
        }
        for (k, v) in &req.headers {
            let lk = k.to_ascii_lowercase();
            if k.is_empty()
                || !k.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
                || v.len() > MAX_HEADER_BYTES
                || v.bytes().any(|b| b == b'\r' || b == b'\n')
            {
                return Err(format!("请求头不合法：{k}"));
            }
            // 由宿主 / HTTP 栈决定的头不让插件改。
            if matches!(lk.as_str(), "host" | "content-length" | "connection" | "transfer-encoding") {
                return Err(format!("不允许设置请求头 {k}"));
            }
        }
        let timeout = match req.timeout_ms {
            0 => HTTP_TIMEOUT_DEFAULT,
            t => t.clamp(1000, HTTP_TIMEOUT_MAX),
        };
        Ok(json!({
            "url": url,
            "method": req.method,
            "headers": req.headers,
            "timeoutMs": timeout,
        }))
    }

    fn check_credentials(&self, op: &str, args: &Json) -> Result<Json, String> {
        if !self.manifest.has_permission("credentials") {
            return Err("插件没有 credentials 权限".into());
        }
        let key = args
            .get("key")
            .and_then(Json::as_str)
            .ok_or("credentials 需要 key")?;
        if key.is_empty() || key.len() > 256 {
            return Err("credentials key 为空或过长".into());
        }
        if op == "credentials.set" {
            let value = args
                .get("value")
                .and_then(Json::as_str)
                .ok_or("credentials.set 需要字符串 value")?;
            if value.len() > crate::plugin::vault::MAX_VALUE_BYTES {
                return Err("凭据超过 64 KiB".into());
            }
            return Ok(json!({ "key": key, "value": value }));
        }
        // 只交出核对过的字段，不原样转发：插件能改写 JSON.stringify / toJSON 往参数里塞
        // `plugin` / `op`，宿主若展开原参数就会以别的插件的名义读写凭据（跨插件越权）。
        Ok(json!({ "key": key }))
    }

    fn check_storage(&self, op: &str, args: &Json) -> Result<Json, String> {
        if !self.manifest.has_permission("storage") {
            return Err("插件没有 storage 权限".into());
        }
        let key = args
            .get("key")
            .and_then(Json::as_str)
            .ok_or("storage 需要 key")?;
        if key.is_empty() || key.len() > MAX_STORAGE_KEY {
            return Err("storage key 为空或过长".into());
        }
        if op == "storage.set" {
            let value = args
                .get("value")
                .and_then(Json::as_str)
                .ok_or("storage.set 需要字符串 value")?;
            if value.len() > MAX_STORAGE_VALUE {
                return Err("storage value 超过 1 MiB".into());
            }
            return Ok(json!({ "key": key, "value": value }));
        }
        // 同 check_credentials：只交出核对过的字段。
        Ok(json!({ "key": key }))
    }
}

/// 一次 [Instance::step] 的输入操作。
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum Op {
    /// 发起能力调用；`inv` 由宿主分配、在本实例内唯一。
    Invoke { inv: u64, method: String, #[serde(default)] args: Json },
    /// 交回宿主调用结果：成功时 `value` 是任意 JSON，失败时 `error` 是错误信息。`value` 是对象且带
    /// `body: {off, len}` 时，这段字节从 step 输入的二进制区切出、以 Uint8Array 交给 JS（响应体
    /// 不经 base64 / JSON）。
    Complete {
        call: u64,
        ok: bool,
        #[serde(default)]
        value: Json,
        #[serde(default)]
        error: String,
    },
}

pub struct Instance {
    rt: Runtime,
    ctx: Context,
    gate: Arc<Gate>,
    deadline: Arc<AtomicU64>,
    budget_ms: u64,
    fatal: Option<String>,
}

/// 单调毫秒时钟（预算计时用）：系统时间被往回拨时 `SystemTime` 会让 deadline 长时间不触发。
/// 从进程内首次调用起算、+1 保证非 0（0 是「未布防」哨兵）。
fn now_ms() -> u64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_millis() as u64 + 1
}

fn exception_text(ctx: &Ctx<'_>, e: rquickjs::Error) -> String {
    if let rquickjs::Error::Exception = e {
        let v = ctx.catch();
        if let Some(ex) = v.as_exception() {
            let msg = ex.message().unwrap_or_default();
            let stack = ex.stack().unwrap_or_default();
            return if stack.is_empty() { msg } else { format!("{msg}\n{stack}") };
        }
        return ctx
            .json_stringify(v)
            .ok()
            .flatten()
            .and_then(|s| s.to_string().ok())
            .unwrap_or_else(|| "未知 JS 异常".into());
    }
    e.to_string()
}

impl Instance {
    /// 用已校验的包建实例：跑前奏、加载入口模块、核对声明的能力都有同名导出。
    pub fn open(pkg: VerifiedPackage, budget_ms: u64) -> Result<Instance, String> {
        let mut sources = BTreeMap::new();
        for (path, bytes) in &pkg.files {
            if path.ends_with(".js") {
                let text = String::from_utf8(bytes.clone())
                    .map_err(|_| format!("{path} 不是 UTF-8 文本"))?;
                sources.insert(path.clone(), text);
            }
        }
        let gate = Arc::new(Gate {
            policy: Policy::from_manifest(&pkg.manifest),
            manifest: pkg.manifest,
            sources,
            outbox: Mutex::new(Outbox::default()),
        });
        let rt = Runtime::new().map_err(|e| format!("建 JS 运行时失败：{e}"))?;
        rt.set_memory_limit(MEMORY_LIMIT);
        rt.set_max_stack_size(STACK_LIMIT);
        let deadline = Arc::new(AtomicU64::new(0));
        {
            let deadline = deadline.clone();
            rt.set_interrupt_handler(Some(Box::new(move || {
                let d = deadline.load(Ordering::Relaxed);
                d != 0 && now_ms() > d
            })));
        }
        let ctx = Context::full(&rt).map_err(|e| format!("建 JS 上下文失败：{e}"))?;
        let mut inst = Instance {
            rt,
            ctx,
            gate,
            deadline,
            budget_ms: budget_ms.max(100),
            fatal: None,
        };
        inst.boot()?;
        Ok(inst)
    }

    fn boot(&mut self) -> Result<(), String> {
        let gate = self.gate.clone();
        let entry = gate.manifest.entry.clone();
        let caps = gate.manifest.capabilities.clone();
        self.arm();
        let result = self.ctx.with(|ctx| -> Result<(), String> {
            let native = jsapi::install(&ctx, gate.clone()).map_err(|e| exception_text(&ctx, e))?;
            ctx.globals()
                .set("__n", native)
                .map_err(|e| exception_text(&ctx, e))?;
            ctx.eval::<(), _>(PRELUDE)
                .map_err(|e| format!("前奏执行失败：{}", exception_text(&ctx, e)))?;
            let load: Function = ctx
                .globals()
                .get("__fushi_load_entry")
                .map_err(|e| exception_text(&ctx, e))?;
            load.call::<_, ()>((entry.clone(),))
                .map_err(|e| format!("加载入口 {entry} 失败：{}", exception_text(&ctx, e)))?;
            let exports: Value = ctx
                .globals()
                .get("__fushi_exports")
                .map_err(|e| exception_text(&ctx, e))?;
            let obj = exports
                .as_object()
                .ok_or_else(|| "入口模块没有导出对象（module.exports）".to_string())?;
            for cap in &caps {
                let v: Value = obj.get(cap.as_str()).map_err(|e| exception_text(&ctx, e))?;
                if !v.is_function() {
                    return Err(format!("清单声明了能力 {cap}，入口却没有导出同名函数"));
                }
            }
            Ok(())
        });
        if result.is_ok() {
            // 模块顶层可能排了微任务（`Promise.resolve().then(...)`）：必须在同一份 CPU 预算内
            // 跑掉——先 disarm 再跑会让微任务里的死循环永不中断，open 永不返回、实例占死一个线程
            // 且无法卸载。日志留到第一次 step 交出。
            self.run_jobs();
        }
        let over = self.over_budget() || self.fatal.is_some();
        self.disarm();
        result?;
        if let Some(a) = self.gate.outbox.lock().unwrap().abort.take() {
            return Err(a);
        }
        if over {
            return Err(format!("插件加载超过 {} ms CPU 预算，已终止", self.budget_ms));
        }
        Ok(())
    }

    fn arm(&self) {
        self.deadline.store(now_ms() + self.budget_ms, Ordering::Relaxed);
    }

    fn disarm(&self) {
        self.deadline.store(0, Ordering::Relaxed);
    }

    fn over_budget(&self) -> bool {
        let d = self.deadline.load(Ordering::Relaxed);
        d != 0 && now_ms() > d
    }

    fn run_jobs(&mut self) {
        loop {
            match self.rt.execute_pending_job() {
                Ok(true) => continue,
                Ok(false) => break,
                Err(e) => {
                    // 清掉挂在上下文上的异常（不清会在之后的 GC 里破坏引用计数）。
                    let detail = e.0.with(|ctx| exception_text(&ctx, rquickjs::Error::Exception));
                    if self.over_budget() {
                        self.fatal = Some(format!("插件单步 CPU 超过 {} ms，已终止", self.budget_ms));
                        break;
                    }
                    // 普通的任务异常（未处理的 rejection 之外的错误）：记一条日志继续。
                    self.gate
                        .outbox
                        .lock()
                        .unwrap()
                        .log("error", &format!("插件任务抛出未捕获异常：{detail}"));
                }
            }
        }
    }

    pub fn manifest(&self) -> &Manifest {
        &self.gate.manifest
    }

    /// 核对一个由插件交给宿主的地址（音频流 / 封面 / 重定向的下一跳）。
    /// 只读的授权核对面（清单 + 策略），可与 [Instance::step] 并发使用（见 `mod.rs` 的句柄）。
    pub(crate) fn gate(&self) -> Arc<Gate> {
        self.gate.clone()
    }

    pub fn check_url(&self, url: &str, purpose: Purpose) -> Result<String, String> {
        self.gate.policy.check_url(url, purpose)
    }

    /// 执行一批操作并交回结果（见模块文档）。[blob] 是本批 `complete` 引用的二进制区；返回值第二项
    /// 是本 step 新发起的宿主调用引用的二进制区（请求体）。
    pub fn step(&mut self, ops_json: &[u8], blob: &[u8]) -> (Json, Vec<u8>) {
        if let Some(f) = &self.fatal {
            return (json!({ "fatal": f, "settled": [], "calls": [], "logs": [] }), Vec::new());
        }
        let ops: Vec<Op> = match serde_json::from_slice(ops_json) {
            Ok(v) => v,
            Err(e) => return (json!({ "error": format!("step 参数不合法：{e}") }), Vec::new()),
        };
        self.gate.outbox.lock().unwrap().begin_step();
        self.arm();
        let caps = self.gate.manifest.capabilities.clone();
        let mut immediate: Vec<Json> = Vec::new();
        self.ctx.with(|ctx| {
            for op in ops {
                match op {
                    Op::Invoke { inv, method, args } => {
                        if !caps.contains(&method) {
                            immediate.push(json!({
                                "inv": inv, "ok": false,
                                "error": format!("插件没有声明能力 {method}"),
                            }));
                            continue;
                        }
                        self.gate.outbox.lock().unwrap().pending_invs.insert(inv);
                        let r = ctx
                            .globals()
                            .get::<_, Function>("__fushi_invoke")
                            .and_then(|f| f.call::<_, ()>((inv, method.as_str(), args.to_string())));
                        if let Err(e) = r {
                            self.gate.outbox.lock().unwrap().pending_invs.remove(&inv);
                            immediate.push(json!({
                                "inv": inv, "ok": false, "error": exception_text(&ctx, e),
                            }));
                        }
                    }
                    Op::Complete { call, ok, mut value, error } => {
                        // 只认还在途的调用：重复 / 未知 id 不进 JS。
                        if !self.gate.outbox.lock().unwrap().pending_calls.remove(&call) {
                            continue;
                        }
                        let (ok, body, payload) = match take_body(&mut value, blob) {
                            _ if !ok => (false, None, error),
                            Ok(body) => (true, body, value.to_string()),
                            Err(e) => (false, None, e),
                        };
                        let r = ctx.globals().get::<_, Function>("__fushi_complete").and_then(|f| {
                            let body = match body {
                                Some(b) => Some(TypedArray::<u8>::new(ctx.clone(), b)?),
                                None => None,
                            };
                            f.call::<_, ()>((call, ok, payload, body))
                        });
                        if let Err(e) = r {
                            let msg = exception_text(&ctx, e);
                            self.gate.outbox.lock().unwrap().log("error", &msg);
                        }
                    }
                }
            }
        });
        self.run_jobs();
        if self.over_budget() && self.fatal.is_none() {
            self.fatal = Some(format!("插件单步 CPU 超过 {} ms，已终止", self.budget_ms));
        }
        self.disarm();
        let mut out = self.gate.outbox.lock().unwrap();
        if let Some(a) = out.abort.take() {
            if self.fatal.is_none() {
                self.fatal = Some(a);
            }
        }
        let mut settled = std::mem::take(&mut out.settled);
        settled.extend(immediate);
        let calls = std::mem::take(&mut out.calls);
        let out_blob = std::mem::take(&mut out.out_blob);
        let mut logs = std::mem::take(&mut out.logs);
        if out.logs_dropped > 0 {
            logs.push(json!({ "level": "warn", "message": format!("另有 {} 条日志被丢弃", out.logs_dropped) }));
            out.logs_dropped = 0;
        }
        let mut result = json!({ "settled": settled, "calls": calls, "logs": logs });
        if let Some(f) = &self.fatal {
            result["fatal"] = json!(f);
        }
        (result, out_blob)
    }
}

/// 从 complete 的 `value` 里取出 `body: {off, len}` 引用并切出字节（越界 = 宿主协议错误，按失败交回）。
fn take_body(value: &mut Json, blob: &[u8]) -> Result<Option<Vec<u8>>, String> {
    let Some(obj) = value.as_object_mut() else { return Ok(None) };
    let Some(r) = obj.remove("body") else { return Ok(None) };
    let off = r["off"].as_u64().ok_or("响应体引用不合法")? as usize;
    let len = r["len"].as_u64().ok_or("响应体引用不合法")? as usize;
    let end = off.checked_add(len).filter(|&e| e <= blob.len()).ok_or("响应体引用越界")?;
    Ok(Some(blob[off..end].to_vec()))
}

/// 能力调用结束（prelude 经 `n.settle` 回报）。结果过大按失败处理，不把几十 MB 塞回宿主。
pub(crate) fn settle(gate: &Gate, inv: u64, ok: bool, payload: String) {
    let mut out = gate.outbox.lock().unwrap();
    // 只收宿主发起过的能力调用；插件自己调 __fushi_invoke 伪造的结果直接丢弃。
    if !out.pending_invs.remove(&inv) {
        return;
    }
    if out.settled.len() >= MAX_SETTLED_PER_STEP {
        out.fail(format!("单步能力结果超过 {MAX_SETTLED_PER_STEP} 条，插件已终止"));
        return;
    }
    out.settled_bytes += payload.len().min(MAX_RESULT_BYTES + 1);
    if out.settled_bytes > MAX_SETTLED_BYTES_PER_STEP {
        out.fail("单步能力结果超过 16 MiB，插件已终止".into());
        return;
    }
    if ok && payload.len() > MAX_RESULT_BYTES {
        out.settled
            .push(json!({ "inv": inv, "ok": false, "error": "插件返回值超过 8 MiB" }));
        return;
    }
    if ok {
        let value: Json = serde_json::from_str(&payload).unwrap_or(Json::Null);
        out.settled.push(json!({ "inv": inv, "ok": true, "value": value }));
    } else {
        out.settled.push(json!({ "inv": inv, "ok": false, "error": payload }));
    }
}

pub(crate) fn throw(ctx: &Ctx<'_>, msg: &str) -> rquickjs::Error {
    Exception::throw_message(ctx, msg)
}

pub(crate) const API_VERSION: u32 = HOST_API_VERSION;
