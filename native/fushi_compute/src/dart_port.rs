//! 原生 → Dart 的事件出口：投递到 Dart 原生端口（`Dart_PostCObject`），不调 `NativeCallable`。
//!
//! 为什么不用 `NativeCallable.listener`（反馈 Wgbo462Sfc，BUG 见 `docs/bugs/`）：它的跳板属于建它的
//! isolate，isolate 一关（Android 上 audio_service 在 Activity 退出后 `FlutterEngine.destroy()`、
//! 桌面热重启、macOS `NSApp terminate`）VM 就删掉跳板；原生工作线程再调一次就是
//! `runtime_entry.cc: Callback invoked after it has been deleted` → SIGABRT。而进程级引擎（音频分析、
//! 漫画超分、libmpv）活得比 isolate 久，Dart 侧又没有「isolate 将死」的同步钩子可以先摘回调。
//!
//! 端口没有这个问题：`Dart_PostCObject` 可在任意线程调，目标端口已随 isolate 关掉时只返回 false，
//! 消息丢弃、进程无事。Dart 侧把 `NativeApi.postCObject`（VM 导出的 `Dart_PostCObject` 地址，进程内
//! 永久有效）和 `RawReceivePort.sendPort.nativePort` 交过来；新 isolate 起来后再交一次就换了端口。
//!
//! 只用到 `Dart_CObject` 的 `kNull` / `kInt64` / `kArray` 三种，布局见 Dart SDK
//! `include/dart_native_api.h`（该结构按 `DART_API_DL_MAJOR_VERSION` 冻结）。

use std::ffi::c_void;

/// `Dart_CObject_Type`：只用到的几个值。
const KIND_NULL: i32 = 0;
const KIND_INT64: i32 = 3;
const KIND_ARRAY: i32 = 6;

/// `Dart_CObject.value.as_array`。
#[repr(C)]
#[derive(Clone, Copy)]
struct CArray {
    length: isize,
    values: *mut *mut CObject,
}

/// `Dart_CObject.value`。`_layout` 占住联合体里最大的成员（`as_external_typed_data`：一个 int32 enum
/// 加四个指针宽字段，按指针宽对齐后正好五个指针宽），让本结构与 C 侧同大小、同对齐。
#[repr(C)]
union CValue {
    as_int64: i64,
    as_array: CArray,
    _layout: [usize; 5],
}

/// `Dart_CObject`。
#[repr(C)]
pub struct CObject {
    kind: i32,
    value: CValue,
}

impl CObject {
    fn null() -> Self {
        Self {
            kind: KIND_NULL,
            value: CValue { as_int64: 0 },
        }
    }

    fn int64(v: i64) -> Self {
        Self {
            kind: KIND_INT64,
            value: CValue { as_int64: v },
        }
    }

    /// 测试用：读回 `kInt64` 的值（不是这个类型返回 None）。
    #[cfg(test)]
    pub(crate) fn as_int64(&self) -> Option<i64> {
        (self.kind == KIND_INT64).then(|| unsafe { self.value.as_int64 })
    }

    /// 测试用：读回 `kArray` 的元素指针（不是这个类型返回 None）。
    ///
    /// # Safety
    /// 只能在 `Dart_PostCObject` 的调用期间读（数组在调用方栈上）。
    #[cfg(test)]
    pub(crate) unsafe fn as_array(&self) -> Option<&[*mut CObject]> {
        if self.kind != KIND_ARRAY {
            return None;
        }
        let a = self.value.as_array;
        Some(std::slice::from_raw_parts(a.values, a.length as usize))
    }

    /// 测试用：是不是 `kNull`。
    #[cfg(test)]
    pub(crate) fn is_null(&self) -> bool {
        self.kind == KIND_NULL
    }
}

/// `Dart_PostCObject` 的签名（Dart 侧 `NativeApi.postCObject`）。C `bool` 与 Rust `bool` ABI 相同。
pub type PostCObject = unsafe extern "C" fn(port: i64, message: *mut CObject) -> bool;

/// 一个 Dart 原生端口。`Copy`：引擎在锁里取一份、锁外投递。
#[derive(Clone, Copy, Debug)]
pub struct DartPort {
    post: PostCObject,
    port: i64,
}

impl DartPort {
    /// [post] 为空返回 None（调用方据此报 `NULL_ARGUMENT`）。
    pub fn new(post: Option<PostCObject>, port: i64) -> Option<Self> {
        post.map(|post| Self { post, port })
    }

    /// 投递一组整数（Dart 侧收到 `List<Object?>`，元素都是 `int`）。返回是否投递成功：端口已随
    /// isolate 关掉时为 false，调用方照常继续（消息本就没人收了）。
    pub fn post_ints(&self, values: &[i64]) -> bool {
        let mut items: Vec<CObject> = values.iter().map(|&v| CObject::int64(v)).collect();
        let mut ptrs: Vec<*mut CObject> = items.iter_mut().map(|c| c as *mut CObject).collect();
        let mut message = CObject {
            kind: KIND_ARRAY,
            value: CValue {
                as_array: CArray {
                    length: ptrs.len() as isize,
                    values: ptrs.as_mut_ptr(),
                },
            },
        };
        // SAFETY: `message` 与它引用的 `items` / `ptrs` 在调用期间都活着；`Dart_PostCObject` 只在调用内
        // 读它们（文档：发送期间不得访问，返回后图完整复原）。
        unsafe { (self.post)(self.port, &mut message) }
    }

    /// 投递一个整数。
    pub fn post_int(&self, value: i64) -> bool {
        let mut message = CObject::int64(value);
        // SAFETY: 同 [post_ints]。
        unsafe { (self.post)(self.port, &mut message) }
    }

    /// 投递 `null`（只当「有事了」的信号）。
    pub fn post_null(&self) -> bool {
        let mut message = CObject::null();
        // SAFETY: 同 [post_ints]。
        unsafe { (self.post)(self.port, &mut message) }
    }
}

/// 「唤醒一下」的目标：端口 + 投递的整数。给只接受 `void (*)(void *data)` 唤醒回调的 C 库用
/// （libmpv 的 `mpv_set_wakeup_callback`）：回调填 [ffc_port_signal_fire]，`data` 填
/// [ffc_port_signal_new] 返回的指针。
struct PortSignal {
    port: DartPort,
    value: i64,
}

/// 建一个唤醒目标：之后每次 [ffc_port_signal_fire] 都把 `value` 投到 `port`。`post` 为空返回空指针。
///
/// 返回的指针要在外部库**保证不再调用** [ffc_port_signal_fire] 之后才能 [ffc_port_signal_free]
/// （libmpv：`mpv_set_wakeup_callback(ctx, NULL, NULL)` 返回后）。外部库可能活得比 Dart isolate 久，
/// 那时就让它一直留着：端口关了投递只是失败，不会崩。
#[no_mangle]
pub extern "C" fn ffc_port_signal_new(
    post: Option<PostCObject>,
    port: i64,
    value: i64,
) -> *mut c_void {
    match DartPort::new(post, port) {
        Some(port) => Box::into_raw(Box::new(PortSignal { port, value })) as *mut c_void,
        None => std::ptr::null_mut(),
    }
}

/// 唤醒：把建目标时给的整数投到它的端口。签名就是 C 库的 `void (*)(void *)`，任意线程可调。
///
/// # Safety
/// `target` 为空或是 [ffc_port_signal_new] 返回、尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn ffc_port_signal_fire(target: *mut c_void) {
    if let Some(signal) = (target as *const PortSignal).as_ref() {
        // 投递失败（端口已关）没人可告诉，也不需要：没有收件人了。
        let _ = signal.port.post_int(signal.value);
    }
}

/// 释放唤醒目标（空指针无操作）。
///
/// # Safety
/// `target` 为空或是 [ffc_port_signal_new] 返回、尚未释放的指针，且之后不会再被 fire。
#[no_mangle]
pub unsafe extern "C" fn ffc_port_signal_free(target: *mut c_void) {
    if !target.is_null() {
        drop(Box::from_raw(target as *mut PortSignal));
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Mutex;

    /// 测试用的「Dart_PostCObject」：把消息解码记下来；`DEAD_PORT` 模拟已关的端口（返回 false）。
    pub(crate) const DEAD_PORT: i64 = -1;

    #[derive(Debug, PartialEq, Eq, Clone)]
    pub(crate) enum Decoded {
        Null,
        Int(i64),
        Ints(Vec<i64>),
    }

    pub(crate) static POSTED: Mutex<Vec<(i64, Decoded)>> = Mutex::new(Vec::new());

    pub(crate) unsafe extern "C" fn fake_post(port: i64, message: *mut CObject) -> bool {
        let m = &*message;
        let decoded = if m.is_null() {
            Decoded::Null
        } else if let Some(v) = m.as_int64() {
            Decoded::Int(v)
        } else if let Some(items) = m.as_array() {
            Decoded::Ints(
                items
                    .iter()
                    .map(|&p| (*p).as_int64().expect("int64 element"))
                    .collect(),
            )
        } else {
            panic!("unexpected Dart_CObject kind {}", m.kind);
        };
        if port == DEAD_PORT {
            return false;
        }
        POSTED
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .push((port, decoded));
        true
    }

    /// 取走某端口收到的消息（并行测试各用各的端口号）。
    pub(crate) fn take(port: i64) -> Vec<Decoded> {
        let mut all = POSTED.lock().unwrap_or_else(|p| p.into_inner());
        let (mine, rest): (Vec<_>, Vec<_>) = all.drain(..).partition(|(p, _)| *p == port);
        *all = rest;
        mine.into_iter().map(|(_, d)| d).collect()
    }

    #[test]
    fn layout_matches_dart_native_api_h() {
        // dart_native_api.h：type 是 int32 enum，union 按 8 字节（64 位）对齐、最大成员 5 个字段。
        let ptr = std::mem::size_of::<usize>();
        assert_eq!(
            std::mem::align_of::<CObject>(),
            std::mem::align_of::<i64>().max(ptr)
        );
        assert_eq!(
            std::mem::offset_of!(CObject, value),
            std::mem::align_of::<CValue>()
        );
        assert_eq!(std::mem::size_of::<CArray>(), 2 * ptr);
    }

    #[test]
    fn posts_ints_null_and_single_int() {
        let port = DartPort::new(Some(fake_post), 9001).unwrap();
        assert!(port.post_ints(&[1, -2, i64::MAX]));
        assert!(port.post_int(42));
        assert!(port.post_null());
        assert_eq!(
            take(9001),
            vec![
                Decoded::Ints(vec![1, -2, i64::MAX]),
                Decoded::Int(42),
                Decoded::Null
            ]
        );
    }

    #[test]
    fn closed_port_is_reported_not_fatal() {
        let port = DartPort::new(Some(fake_post), DEAD_PORT).unwrap();
        assert!(!port.post_ints(&[1, 2]));
        assert!(!port.post_int(1));
    }

    #[test]
    fn missing_post_function_is_rejected() {
        assert!(DartPort::new(None, 1).is_none());
        assert!(ffc_port_signal_new(None, 1, 2).is_null());
    }

    #[test]
    fn port_signal_fires_its_value_until_freed() {
        let target = ffc_port_signal_new(Some(fake_post), 9002, 0x7f00_dead_beef);
        assert!(!target.is_null());
        unsafe {
            ffc_port_signal_fire(target);
            ffc_port_signal_fire(target);
            ffc_port_signal_fire(std::ptr::null_mut());
            ffc_port_signal_free(target);
            ffc_port_signal_free(std::ptr::null_mut());
        }
        assert_eq!(
            take(9002),
            vec![
                Decoded::Int(0x7f00_dead_beef),
                Decoded::Int(0x7f00_dead_beef)
            ]
        );
    }

    #[test]
    fn port_signal_to_closed_port_does_not_crash() {
        let target = ffc_port_signal_new(Some(fake_post), DEAD_PORT, 5);
        unsafe {
            ffc_port_signal_fire(target);
            ffc_port_signal_free(target);
        }
    }
}
