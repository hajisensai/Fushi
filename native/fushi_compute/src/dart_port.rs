//! 原生线程 → Dart 的事件通道：往 Dart `ReceivePort` 的原生端口发消息（`Dart_PostCObject`）。
//!
//! 为什么不用 `NativeCallable.listener`（BUG-5413，反馈 Wgbo462Sfc）：listener 的函数指针归属创建它的
//! isolate，isolate 一销毁 VM 就把它删掉，之后再调直接 `FATAL("Callback invoked after it has been
//! deleted")` 把整个进程 abort。而本库的工作线程（音乐分析、超分）和 libmpv 的核心线程都是进程级的，
//! 活得比 isolate 久：Android 上 audio_service 在 Activity 走后 `AudioService.onDestroy` 会
//! `FlutterEngine.destroy()`，进程却留在后台；工作线程这时报一个进度 / 完成事件，进程就没了。
//!
//! 端口没有这个问题：isolate 没了端口就关了，`Dart_PostCObject` 返回 false、消息丢掉，不碰任何已释放
//! 的东西；新 isolate 再登记自己的端口即可。`Dart_PostCObject` 本身是 VM 的进程级入口，由 Dart 侧把
//! `NativeApi.postCObject` 传进来（不用链 dart_api_dl）。
//!
//! 两种用法：
//! - [DartPort]：本库自己的引擎发事件（一条消息 = 一个 `int` 列表）；
//! - [ffc_port_wakeup]：给只认 `void (*)(void*)` 的 C 库（libmpv 的 `mpv_set_wakeup_callback`）当唤醒
//!   回调，`d` 指向调用方分配的 [PortWakeup]，每次唤醒往端口发一个 `int`。

use std::ffi::c_void;

/// `Dart_PostCObject`（`dart_native_api.h`）。
pub type PostCObjectFn = unsafe extern "C" fn(port: i64, message: *mut DartCObject) -> bool;

/// `Dart_CObject_kInt64`。
const KIND_INT64: i32 = 3;
/// `Dart_CObject_kArray`。
const KIND_ARRAY: i32 = 6;

/// `Dart_CObject` 里本库会用到的部分：`type` 之后是 8 字节对齐的值联合体。VM 只按 `type` 读对应成员，
/// 并在 `Dart_PostCObject` 返回前把整条消息复制走，所以这里只需覆盖 int64 与数组两种成员的布局。
#[repr(C)]
pub struct DartCObject {
    kind: i32,
    value: DartCObjectValue,
}

#[repr(C)]
union DartCObjectValue {
    as_int64: i64,
    as_array: DartCObjectArray,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct DartCObjectArray {
    length: isize,
    values: *mut *mut DartCObject,
}

impl DartCObject {
    fn int64(value: i64) -> Self {
        Self {
            kind: KIND_INT64,
            value: DartCObjectValue { as_int64: value },
        }
    }
}

/// 一个 Dart 原生端口（`SendPort.nativePort`）加发送入口。可随意复制、跨线程共享：端口关了也只是发不出去。
#[derive(Clone, Copy)]
pub struct DartPort {
    post: PostCObjectFn,
    port: i64,
}

// 函数指针 + 整数；Dart_PostCObject 可在任意线程调用。
unsafe impl Send for DartPort {}
unsafe impl Sync for DartPort {}

impl DartPort {
    /// `post` 为空返回 None。
    pub fn new(post: Option<PostCObjectFn>, port: i64) -> Option<Self> {
        post.map(|post| Self { post, port })
    }

    /// 端口号（`SendPort.nativePort`）。VM 内唯一，用来分辨「事件该归哪个 isolate」：进程级引擎换了登记端口
    /// = 先前登记的 isolate 已经没了（各引擎只给一个 isolate 用），它留下的任务与事件都不能落到新 isolate 上。
    pub fn port(&self) -> i64 {
        self.port
    }

    /// 发一条 `List<int>` 消息。端口已关（接收的 isolate 没了）返回 false，此外无副作用。
    pub fn post_ints(&self, values: &[i64]) -> bool {
        let mut items: Vec<DartCObject> = values.iter().map(|&v| DartCObject::int64(v)).collect();
        let mut pointers: Vec<*mut DartCObject> = items
            .iter_mut()
            .map(|item| item as *mut DartCObject)
            .collect();
        let mut message = DartCObject {
            kind: KIND_ARRAY,
            value: DartCObjectValue {
                as_array: DartCObjectArray {
                    length: pointers.len() as isize,
                    values: pointers.as_mut_ptr(),
                },
            },
        };
        // 安全：message 及其引用的 items / pointers 在调用期间都活着；VM 在返回前复制完消息。
        unsafe { (self.post)(self.port, &mut message) }
    }
}

/// [ffc_port_wakeup] 的 `d`：由调用方分配（C 布局），在 C 库可能调回调期间一直有效。
#[repr(C)]
pub struct PortWakeup {
    /// `NativeApi.postCObject`。
    pub post: Option<PostCObjectFn>,
    /// 接收端 `SendPort.nativePort`。
    pub port: i64,
    /// 每次唤醒发出的值（libmpv：`mpv_handle` 地址）。
    pub value: i64,
}

/// `void (*)(void*)` 形态的唤醒回调：把 `d`（[PortWakeup]）的 `value` 作为一个 `int` 发到 `port`。
/// 接收的 isolate 没了也安全（消息丢掉），所以可以交给活得比 isolate 久的 C 库线程。
///
/// # Safety
/// `d` 为空（什么也不做）或指向有效的 [PortWakeup]。
#[no_mangle]
pub unsafe extern "C" fn ffc_port_wakeup(d: *mut c_void) {
    let Some(wakeup) = (d as *const PortWakeup).as_ref() else {
        return;
    };
    if let Some(post) = wakeup.post {
        let mut message = DartCObject::int64(wakeup.value);
        post(wakeup.port, &mut message);
    }
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// 按端口号收集测试里「发到 Dart」的消息（解码成 int 列表；单个 int 记成一元列表）。
    static INBOX: Mutex<Option<HashMap<i64, Vec<Vec<i64>>>>> = Mutex::new(None);

    /// 解码一条只含 int64 / int64 数组的消息。
    ///
    /// # Safety
    /// `message` 指向 [DartPort::post_ints] / [ffc_port_wakeup] 构造的消息。
    pub(crate) unsafe fn decode(message: *const DartCObject) -> Vec<i64> {
        let message = &*message;
        match message.kind {
            KIND_INT64 => vec![message.value.as_int64],
            KIND_ARRAY => {
                let array = message.value.as_array;
                (0..array.length)
                    .map(|i| {
                        let item = &**array.values.offset(i);
                        assert_eq!(item.kind, KIND_INT64);
                        item.value.as_int64
                    })
                    .collect()
            }
            other => panic!("unexpected Dart_CObject type {other}"),
        }
    }

    /// 假的 `Dart_PostCObject`：端口号为负当作「已关」（返回 false、不收），否则收进 [INBOX]。
    pub(crate) unsafe extern "C" fn fake_post(port: i64, message: *mut DartCObject) -> bool {
        if port < 0 {
            return false;
        }
        let decoded = decode(message);
        INBOX
            .lock()
            .unwrap()
            .get_or_insert_with(HashMap::new)
            .entry(port)
            .or_default()
            .push(decoded);
        true
    }

    /// 一个只给本测试用的端口（各测试用不同端口号，互不干扰）。
    pub(crate) fn port(id: i64) -> DartPort {
        DartPort::new(Some(fake_post), id).unwrap()
    }

    /// 端口 [id] 迄今收到的消息。
    pub(crate) fn received(id: i64) -> Vec<Vec<i64>> {
        INBOX
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|m| m.get(&id).cloned())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;

    #[test]
    fn posts_int_lists_and_survives_a_closed_port() {
        let open = port(9001);
        assert!(open.post_ints(&[4, -1, u32::MAX as i64]));
        assert!(open.post_ints(&[]));
        assert_eq!(received(9001), vec![vec![4, -1, u32::MAX as i64], vec![]]);
        // 接收的 isolate 没了：发不出去、不崩，也不影响别的端口。
        let closed = port(-9001);
        assert!(!closed.post_ints(&[1, 2]));
        assert_eq!(received(9001).len(), 2);
    }

    #[test]
    fn missing_post_entry_is_rejected() {
        assert!(DartPort::new(None, 1).is_none());
    }

    #[test]
    fn wakeup_trampoline_posts_the_value_and_ignores_null() {
        let wakeup = PortWakeup {
            post: Some(fake_post),
            port: 9002,
            value: 0x1234_5678_9abc,
        };
        unsafe {
            ffc_port_wakeup(&wakeup as *const PortWakeup as *mut c_void);
            ffc_port_wakeup(&wakeup as *const PortWakeup as *mut c_void);
            ffc_port_wakeup(std::ptr::null_mut());
        }
        assert_eq!(
            received(9002),
            vec![vec![0x1234_5678_9abc], vec![0x1234_5678_9abc]]
        );
        let closed = PortWakeup {
            post: Some(fake_post),
            port: -9002,
            value: 1,
        };
        unsafe { ffc_port_wakeup(&closed as *const PortWakeup as *mut c_void) };
    }

    /// 与 `dart_native_api.h` 的 `Dart_CObject` 对齐：值联合体从 8 字节处开始（32 / 64 位都一样，
    /// 联合体里有 int64）；数组成员是 `intptr_t length` 后接指针。
    #[test]
    fn layout_matches_dart_native_api() {
        assert_eq!(std::mem::offset_of!(DartCObject, value), 8);
        assert_eq!(
            std::mem::offset_of!(DartCObjectArray, values),
            std::mem::size_of::<isize>()
        );
        assert_eq!(std::mem::offset_of!(PortWakeup, port), 8);
        assert_eq!(std::mem::offset_of!(PortWakeup, value), 16);
    }
}
