//! 资源管理器进程里的一侧：把一个文件交给宿主进程 `fushi_shell_thumbs_host.exe` 解析，
//! 带超时、内存上限地取回缩略图。
//!
//! 为什么不在资源管理器进程里直接解析：本处理器按用户安装（HKCU），实测（2026-11-16，
//! Windows 11）系统的缩略图隔离进程（COM Surrogate，AppID `{AB8902B4-…}`）激活不到 HKCU 里
//! 注册的 CLSID（`REGDB_E_CLASSNOTREG`），只能 `DisableProcessIsolation=1` 进程内加载。于是隔离
//! 由我们自己做：解析不可信文件（zip / 7z.dll / pdfium.dll）全在一次性的子进程里，崩溃、卡死、
//! 吃内存都只丢这一张缩略图，拖不垮 explorer.exe。
//!
//! 资源边界（BUG-4771）：
//! - 宿主进程**创建时**就在 job 里（`PROC_THREAD_ATTRIBUTE_JOB_LIST`，Win10+），不存在
//!   「先启动、后 AssignProcessToJobObject」之间不受限的窗口；job 建不出来或入 job 失败，
//!   CreateProcessW 直接失败，宿主根本不会运行。
//! - 同时存在的宿主数由进程级 [`HOST_SLOTS`] 限到 [`MAX_CONCURRENT_HOSTS`]，所以 explorer
//!   并发请求再多，宿主占用的内存总量也不超过 `MAX_CONCURRENT_HOSTS × MEMORY_LIMIT`。

use std::ffi::{OsStr, c_void};
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{
    CloseHandle, FreeLibrary, HANDLE, HANDLE_FLAG_INHERIT, HANDLE_FLAGS, HMODULE,
    SetHandleInformation, WAIT_OBJECT_0,
};
use windows::Win32::Security::SECURITY_ATTRIBUTES;
use windows::Win32::System::JobObjects::{
    CreateJobObjectW, JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOB_OBJECT_LIMIT_PROCESS_MEMORY,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject,
};
use windows::Win32::System::LibraryLoader::{
    FreeLibraryAndExitThread, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, GetModuleHandleExW,
};
use windows::Win32::System::Pipes::CreatePipe;
use windows::Win32::System::Threading::{
    CREATE_NO_WINDOW, CreateProcessW, CreateThread, DeleteProcThreadAttributeList,
    EXTENDED_STARTUPINFO_PRESENT, GetExitCodeProcess, INFINITE, InitializeProcThreadAttributeList,
    LPPROC_THREAD_ATTRIBUTE_LIST, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
    PROC_THREAD_ATTRIBUTE_JOB_LIST, PROCESS_INFORMATION, STARTF_USESTDHANDLES, STARTUPINFOEXW,
    THREAD_CREATION_FLAGS, TerminateProcess, UpdateProcThreadAttribute, WaitForSingleObject,
};
use windows::core::{BOOL, PCWSTR, PWSTR};

use crate::{ThumbError, Thumbnail, wire};

/// 宿主可执行文件名（与本 DLL 同目录，即 `{app}`）。
pub const HOST_EXE: &str = "fushi_shell_thumbs_host.exe";

/// 单张缩略图的总时限（含排队等宿主名额与进程启动）。资源管理器自己也有超时，这里保证子进程
/// 一定被收走。
const TIMEOUT: Duration = Duration::from_secs(15);

/// 单个宿主进程的内存上限。
const MEMORY_LIMIT: usize = 1024 * 1024 * 1024;

/// 同时存在的宿主进程上限。宿主内存总量因此不超过 `MAX_CONCURRENT_HOSTS × MEMORY_LIMIT`；
/// 超出的请求排队（共用 [`TIMEOUT`]），不是直接失败。
const MAX_CONCURRENT_HOSTS: usize = 4;

/// 本 DLL（explorer.exe 进程内）的宿主名额。
static HOST_SLOTS: HostSlots = HostSlots::new(MAX_CONCURRENT_HOSTS);

/// 计数信号量：限制同时存在的宿主进程数。
struct HostSlots {
    in_use: Mutex<usize>,
    freed: Condvar,
    capacity: usize,
}

/// 一个宿主名额；析构时归还。必须活得比它对应的宿主进程久（宿主先被收走、名额再还）。
struct HostSlot<'a>(&'a HostSlots);

impl HostSlots {
    const fn new(capacity: usize) -> HostSlots {
        HostSlots {
            in_use: Mutex::new(0),
            freed: Condvar::new(),
            capacity,
        }
    }

    /// 计数本身不会因 panic 处于半更新状态（加减都是一条语句），所以中毒时照常取用。
    fn lock(&self) -> MutexGuard<'_, usize> {
        self.in_use
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// 等一个名额，最多等到 `deadline`；到点仍没有就返回 `None`。
    fn acquire(&self, deadline: Instant) -> Option<HostSlot<'_>> {
        let mut in_use = self.lock();
        while *in_use >= self.capacity {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            in_use = self
                .freed
                .wait_timeout(in_use, remaining)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
        *in_use += 1;
        Some(HostSlot(self))
    }
}

impl Drop for HostSlot<'_> {
    fn drop(&mut self) {
        *self.0.lock() -= 1;
        self.0.freed.notify_one();
    }
}

/// 关闭时杀掉其中进程的 job（KILL_ON_JOB_CLOSE）。
struct Job(HANDLE);

impl Job {
    fn new() -> Result<Job, ThumbError> {
        // SAFETY: 匿名 job；limits 结构在调用期间存活。
        unsafe {
            let h = CreateJobObjectW(None, None)
                .map_err(|e| ThumbError::Io(format!("create thumbnail host job: {e}")))?;
            let job = Job(h);
            let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                | JOB_OBJECT_LIMIT_PROCESS_MEMORY
                | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
            info.ProcessMemoryLimit = MEMORY_LIMIT;
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const core::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
            .map_err(|e| ThumbError::Io(format!("limit thumbnail host job: {e}")))?;
            Ok(job)
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        // SAFETY: 句柄由 CreateJobObjectW 创建、只关一次。
        let _ = unsafe { CloseHandle(self.0) };
    }
}

/// 一个已启动的宿主进程。析构时若还在跑就终止并等它退出，所以持有的名额只在进程真正结束后
/// 才归还。
struct HostProcess {
    process: OwnedHandle,
}

impl HostProcess {
    fn handle(&self) -> HANDLE {
        HANDLE(self.process.as_raw_handle())
    }

    /// 等进程退出，最多 `timeout`；返回是否已退出。
    fn wait(&self, timeout: Duration) -> bool {
        let millis = u32::try_from(timeout.as_millis()).unwrap_or(INFINITE - 1);
        // SAFETY: handle 是本结构持有的有效进程句柄。
        unsafe { WaitForSingleObject(self.handle(), millis) == WAIT_OBJECT_0 }
    }

    fn exit_code(&self) -> Result<u32, ThumbError> {
        let mut code = 0u32;
        // SAFETY: handle 有效；code 在调用期间存活。
        unsafe { GetExitCodeProcess(self.handle(), &mut code) }
            .map_err(|e| ThumbError::Io(format!("thumbnail host exit code: {e}")))?;
        Ok(code)
    }

    /// 终止并等到进程真正退出（与 `std::process::Child::kill` + `wait` 同义）。进程已经自己退出
    /// 时 TerminateProcess 会失败，那正是想要的结果，所以只看随后的等待。
    fn kill(&self) {
        // SAFETY: handle 有效。
        unsafe {
            let _ = TerminateProcess(self.handle(), 1);
            WaitForSingleObject(self.handle(), INFINITE);
        }
    }
}

impl Drop for HostProcess {
    fn drop(&mut self) {
        if !self.wait(Duration::ZERO) {
            self.kill();
        }
    }
}

/// 把 `arg` 按 MSVC CRT / `CommandLineToArgvW` 的规则追加进命令行（与 std 的 `Command`
/// 一致：只在含空白或为空时加引号；引号内，紧贴 `"` 或结尾引号的反斜杠成倍）。
fn append_arg(cmd: &mut Vec<u16>, arg: &OsStr) {
    const QUOTE: u16 = b'"' as u16;
    const BACKSLASH: u16 = b'\\' as u16;
    let wide: Vec<u16> = arg.encode_wide().collect();
    if !cmd.is_empty() {
        cmd.push(b' ' as u16);
    }
    let quote = wide.is_empty()
        || wide
            .iter()
            .any(|&c| c == b' ' as u16 || c == b'\t' as u16 || c == QUOTE);
    if !quote {
        cmd.extend_from_slice(&wide);
        return;
    }
    cmd.push(QUOTE);
    let mut backslashes = 0usize;
    for &c in &wide {
        if c == BACKSLASH {
            backslashes += 1;
            continue;
        }
        if c == QUOTE {
            cmd.extend(std::iter::repeat_n(BACKSLASH, backslashes * 2 + 1));
        } else {
            cmd.extend(std::iter::repeat_n(BACKSLASH, backslashes));
        }
        backslashes = 0;
        cmd.push(c);
    }
    cmd.extend(std::iter::repeat_n(BACKSLASH, backslashes * 2));
    cmd.push(QUOTE);
}

/// 组装完整命令行（含程序名）。
fn command_line(exe: &Path, args: &[&OsStr]) -> Vec<u16> {
    let mut cmd = Vec::new();
    append_arg(&mut cmd, exe.as_os_str());
    for arg in args {
        append_arg(&mut cmd, arg);
    }
    cmd
}

fn wide_nul(s: &OsStr) -> Vec<u16> {
    s.encode_wide().chain(std::iter::once(0)).collect()
}

fn set_inheritable(handle: HANDLE, inheritable: bool) -> std::io::Result<()> {
    let flags = if inheritable {
        HANDLE_FLAG_INHERIT
    } else {
        HANDLE_FLAGS(0)
    };
    // SAFETY: handle 是调用方持有的有效句柄。
    unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT.0, flags) }
        .map_err(std::io::Error::other)
}

/// 进程 / 线程属性列表（`InitializeProcThreadAttributeList` 的缓冲区），析构时删除。
struct AttributeList {
    buffer: Vec<usize>,
}

impl AttributeList {
    fn new(count: u32) -> std::io::Result<AttributeList> {
        let mut size = 0usize;
        // 第一次调用只为取所需大小：按文档它必然返回 FALSE（ERROR_INSUFFICIENT_BUFFER），
        // 有用的只是 size。
        // SAFETY: 空列表指针 + size 出参，这是文档规定的取大小方式。
        let _ = unsafe { InitializeProcThreadAttributeList(None, count, None, &mut size) };
        let mut buffer = vec![0usize; size.div_ceil(std::mem::size_of::<usize>())];
        let list = LPPROC_THREAD_ATTRIBUTE_LIST(buffer.as_mut_ptr().cast());
        // SAFETY: buffer 至少 size 字节且按指针对齐。
        unsafe { InitializeProcThreadAttributeList(Some(list), count, None, &mut size) }
            .map_err(std::io::Error::other)?;
        Ok(AttributeList { buffer })
    }

    fn as_raw(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        LPPROC_THREAD_ATTRIBUTE_LIST(self.buffer.as_mut_ptr().cast())
    }

    /// `value` 必须活到 CreateProcessW 返回（属性列表只存指针）。
    fn set<T>(&mut self, attribute: u32, value: &[T]) -> std::io::Result<()> {
        // SAFETY: 列表已初始化；value 指向 len 个 T，调用方保证它活到 CreateProcessW 之后。
        unsafe {
            UpdateProcThreadAttribute(
                self.as_raw(),
                0,
                attribute as usize,
                Some(value.as_ptr().cast()),
                std::mem::size_of_val(value),
                None,
                None,
            )
        }
        .map_err(std::io::Error::other)
    }
}

impl Drop for AttributeList {
    fn drop(&mut self) {
        // SAFETY: 列表由 new 初始化成功，只删一次。
        unsafe { DeleteProcThreadAttributeList(self.as_raw()) }
    }
}

/// 在 `job` 里创建进程：`PROC_THREAD_ATTRIBUTE_JOB_LIST` 让进程从第一条指令起就受 job 限制；
/// 入 job 失败时 CreateProcessW 整体失败、进程不会存在。stdin / stderr 接 NUL，stdout 接一根
/// 匿名管道（返回其读端）；`PROC_THREAD_ATTRIBUTE_HANDLE_LIST` 让子进程只继承这两个句柄。
fn spawn_in_job(
    exe: &Path,
    args: &[&OsStr],
    cwd: &Path,
    job: &Job,
) -> std::io::Result<(HostProcess, File)> {
    let nul = OpenOptions::new().read(true).write(true).open("NUL")?;
    let nul_handle = HANDLE(nul.as_raw_handle());
    set_inheritable(nul_handle, true)?;

    let (read_end, write_end) = {
        let mut read = HANDLE::default();
        let mut write = HANDLE::default();
        let inherit = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: std::ptr::null_mut(),
            bInheritHandle: BOOL(1),
        };
        // SAFETY: 出参与 SECURITY_ATTRIBUTES 在调用期间存活；成功后两个句柄立刻交给 OwnedHandle。
        unsafe { CreatePipe(&mut read, &mut write, Some(&inherit), 0) }
            .map_err(std::io::Error::other)?;
        // SAFETY: 两个句柄刚由 CreatePipe 创建，所有权唯一。
        unsafe {
            (
                OwnedHandle::from_raw_handle(read.0),
                OwnedHandle::from_raw_handle(write.0),
            )
        }
    };
    let read_handle = HANDLE(read_end.as_raw_handle());
    let write_handle = HANDLE(write_end.as_raw_handle());
    // 读端留在本进程，不给任何子进程。
    set_inheritable(read_handle, false)?;

    let inherited: [HANDLE; 2] = [nul_handle, write_handle];
    let jobs: [HANDLE; 1] = [job.0];
    let mut attributes = AttributeList::new(2)?;
    attributes.set(PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherited)?;
    attributes.set(PROC_THREAD_ATTRIBUTE_JOB_LIST, &jobs)?;

    let mut startup = STARTUPINFOEXW::default();
    startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = nul_handle;
    startup.StartupInfo.hStdOutput = write_handle;
    startup.StartupInfo.hStdError = nul_handle;
    startup.lpAttributeList = attributes.as_raw();

    let application = wide_nul(exe.as_os_str());
    let mut cmd = command_line(exe, args);
    cmd.push(0);
    let directory = wide_nul(cwd.as_os_str());
    let mut info = PROCESS_INFORMATION::default();
    // 不降优先级（不加 BELOW_NORMAL_PRIORITY_CLASS）：缩略图是用户正盯着的前台工作。实测
    // （2026-11-16）机器满载时低优先级宿主会被饿到超时，约 1/12 的缩略图失败；普通优先级下
    // 84/84 成功。
    // SAFETY: 所有字符串以 NUL 结尾并活到调用结束；startup 引用的属性列表、句柄数组同样存活；
    // cmd 可写（CreateProcessW 可能原地改写命令行缓冲区）。
    unsafe {
        CreateProcessW(
            PCWSTR(application.as_ptr()),
            Some(PWSTR(cmd.as_mut_ptr())),
            None,
            None,
            true,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
            None,
            PCWSTR(directory.as_ptr()),
            &startup.StartupInfo,
            &mut info,
        )
    }
    .map_err(std::io::Error::other)?;
    // SAFETY: CreateProcessW 成功时两个句柄归调用方所有，各包一次。
    let (process, _thread) = unsafe {
        (
            OwnedHandle::from_raw_handle(info.hProcess.0),
            OwnedHandle::from_raw_handle(info.hThread.0),
        )
    };
    // 本进程的写端副本、NUL 句柄随作用域关闭；子进程退出后读端才能读到 EOF。
    drop(attributes);
    drop(write_end);
    drop(nul);
    Ok((HostProcess { process }, File::from(read_end)))
}

/// 请宿主进程给 `path` 出一张边长不超过 `cx` 的缩略图。
pub fn request_thumbnail(path: &Path, cx: u32) -> Result<Thumbnail, ThumbError> {
    let dir = super::dependency_dir()
        .ok_or_else(|| ThumbError::MissingDependency("cannot locate module directory".into()))?;
    let host = dir.join(HOST_EXE);
    if !host.is_file() {
        return Err(ThumbError::MissingDependency(host.display().to_string()));
    }
    let cx = cx.clamp(1, wire::MAX_EDGE);
    let deadline = Instant::now() + TIMEOUT;
    // 声明顺序即析构的逆序：宿主进程先被收走，job 再关，名额最后归还。
    let _slot = HOST_SLOTS
        .acquire(deadline)
        .ok_or_else(|| ThumbError::Io("all thumbnail host slots stayed busy".into()))?;
    let job = Job::new()?;
    let cx_arg = cx.to_string();
    let (child, stdout) =
        spawn_in_job(&host, &[OsStr::new(&cx_arg), path.as_os_str()], &dir, &job)?;

    // 宿主写满管道缓冲区就会阻塞，所以边跑边读。按帧头里的尺寸读够就停、不等 EOF：
    // 资源管理器里别的 CreateProcess 若恰好继承了管道写端，EOF 会迟到，但帧已经完整。
    // 读线程可能比本函数活得久（超时 / 宿主失败时不等它），见 [`spawn_frame_reader`]。
    let reader = match spawn_frame_reader(stdout, cx) {
        Ok(reader) => reader,
        Err(e) => {
            child.kill();
            return Err(e);
        }
    };

    if !child.wait(deadline.saturating_duration_since(Instant::now())) {
        child.kill();
        return Err(ThumbError::Io("thumbnail host timed out".into()));
    }
    let code = child.exit_code()?;
    if code != 0 {
        return Err(ThumbError::Corrupt(format!(
            "thumbnail host exited with code {code}"
        )));
    }
    reader.result_before(deadline)
}

/// 读帧线程的句柄 + 结果通道。
///
/// 生命周期：本线程跑在 explorer.exe 里、执行的是本 DLL 的代码，而调用方在超时 / 宿主失败时
/// 不等它（管道写端若被 explorer 里别的 CreateProcess 继承，EOF 会迟到，等它就把资源管理器的
/// 缩略图线程一起拖住）。`DllCanUnloadNow` 只数 COM 对象，所以线程**自己**给本模块加一次
/// 引用计数（`GetModuleHandleExW` 不带 UNCHANGED_REFCOUNT），收尾用
/// `FreeLibraryAndExitThread` 释放并退出——这是 Win32 给「DLL 里起的线程」的标准做法：
/// 资源管理器按 `DllCanUnloadNow == S_OK` 调 FreeLibrary 只会减掉它自己那一份，模块要等这条
/// 线程放手才真正卸载，而线程放手后不再返回到本模块的任何代码里。
struct FrameReader {
    rx: Receiver<Result<Thumbnail, ThumbError>>,
    thread: HANDLE,
}

impl FrameReader {
    /// 等读线程交出结果，最多等到 `deadline`；超时或线程没给结果就报错（线程自行善后）。
    fn result_before(&self, deadline: Instant) -> Result<Thumbnail, ThumbError> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match self.rx.recv_timeout(remaining) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) => {
                Err(ThumbError::Io("thumbnail host frame incomplete".into()))
            }
            Err(RecvTimeoutError::Disconnected) => Err(ThumbError::Io(
                "thumbnail reader ended without a result".into(),
            )),
        }
    }
}

impl Drop for FrameReader {
    fn drop(&mut self) {
        // 只关句柄、不等线程：线程持有自己的模块引用，见类型文档。
        // SAFETY: 句柄由 CreateThread 返回、只关一次。
        let _ = unsafe { CloseHandle(self.thread) };
    }
}

struct ReaderContext<R> {
    source: R,
    cx: u32,
    tx: SyncSender<Result<Thumbnail, ThumbError>>,
    module: HMODULE,
}

unsafe extern "system" fn frame_reader_main<R: Read + Send + 'static>(param: *mut c_void) -> u32 {
    // 所有 Rust 值（管道读端、发送端）在内层作用域里析构完，再把模块引用交还并退出线程；
    // FreeLibraryAndExitThread 不返回，之后不再执行本模块的代码。
    let module = {
        // SAFETY: param 是 spawn_frame_reader 里 Box::into_raw 出来的同类型指针，只取一次。
        let ctx = unsafe { Box::from_raw(param as *mut ReaderContext<R>) };
        let ReaderContext {
            source,
            cx,
            tx,
            module,
        } = *ctx;
        let result = catch_unwind(AssertUnwindSafe(move || wire::read_frame(source, cx)))
            .unwrap_or_else(|_| Err(ThumbError::Io("reader thread panicked".into())));
        // 调用方已经放弃（超时 / 宿主失败）时接收端已析构，发送失败无所谓。
        let _ = tx.send(result);
        module
    };
    // SAFETY: module 是本线程在 spawn_frame_reader 里加过一次引用的本模块句柄。
    unsafe { FreeLibraryAndExitThread(module, 0) }
}

/// 起一条读帧线程，它持有本模块的一份引用直到退出（理由见 [`FrameReader`]）。
fn spawn_frame_reader<R: Read + Send + 'static>(
    source: R,
    cx: u32,
) -> Result<FrameReader, ThumbError> {
    let entry: unsafe extern "system" fn(*mut c_void) -> u32 = frame_reader_main::<R>;
    let mut module = HMODULE::default();
    // SAFETY: FROM_ADDRESS 模式下第二个参数是本模块内任一地址（线程入口本身）；不带
    // UNCHANGED_REFCOUNT，所以引用计数 +1，由线程收尾的 FreeLibraryAndExitThread 抵消。
    unsafe {
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            PCWSTR(entry as usize as *const u16),
            &mut module,
        )
    }
    .map_err(|e| ThumbError::Io(format!("pin module for reader thread: {e}")))?;
    let (tx, rx) = sync_channel(1);
    let ctx = Box::into_raw(Box::new(ReaderContext {
        source,
        cx,
        tx,
        module,
    }));
    // SAFETY: ctx 的所有权交给新线程（frame_reader_main 用 Box::from_raw 收回）；创建失败时
    // 线程没起来，所有权仍在这里，收回并释放模块引用。
    match unsafe {
        CreateThread(
            None,
            0,
            Some(entry),
            Some(ctx as *const c_void),
            THREAD_CREATION_FLAGS(0),
            None,
        )
    } {
        Ok(thread) => Ok(FrameReader { rx, thread }),
        Err(e) => {
            // SAFETY: 见上。
            unsafe {
                drop(Box::from_raw(ctx));
                let _ = FreeLibrary(module);
            }
            Err(ThumbError::Io(format!("spawn reader thread: {e}")))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use windows::Win32::Foundation::WAIT_TIMEOUT;

    use super::*;

    fn frame(width: u32, height: u32) -> Vec<u8> {
        let thumb = Thumbnail {
            width,
            height,
            bgra: vec![0x7f; width as usize * height as usize * 4],
        };
        wire::encode(&thumb)
    }

    fn thread_exited(reader: &FrameReader, wait: Duration) -> bool {
        // SAFETY: thread 是 FrameReader 持有的有效线程句柄。
        unsafe { WaitForSingleObject(reader.thread, wait.as_millis() as u32) == WAIT_OBJECT_0 }
    }

    #[test]
    fn reader_delivers_a_complete_frame() {
        let (rx, mut tx) = std::io::pipe().expect("pipe");
        let reader = spawn_frame_reader(rx, 64).expect("spawn reader");
        tx.write_all(&frame(4, 3)).expect("write frame");
        drop(tx);
        let thumb = reader
            .result_before(Instant::now() + Duration::from_secs(10))
            .expect("frame");
        assert_eq!((thumb.width, thumb.height), (4, 3));
        assert!(thread_exited(&reader, Duration::from_secs(10)));
    }

    /// 调用方先放弃（超时 / 宿主失败分支直接 return），读线程仍被管道阻塞；之后 EOF 到来，
    /// 线程自己收尾退出，不需要任何人 join，也不会因接收端已析构而 panic。
    #[test]
    fn abandoned_reader_finishes_on_its_own_after_eof() {
        let (rx, mut tx) = std::io::pipe().expect("pipe");
        let reader = spawn_frame_reader(rx, 64).expect("spawn reader");
        let partial = frame(4, 3);
        tx.write_all(&partial[..partial.len() / 2])
            .expect("write half");
        let err = reader
            .result_before(Instant::now() + Duration::from_millis(200))
            .expect_err("incomplete frame must not succeed");
        assert!(matches!(err, ThumbError::Io(_)), "{err:?}");
        // 线程还卡在读上：管道写端没关（模拟写端被别的进程继承、EOF 迟到）。
        // SAFETY: 同 thread_exited。
        assert_eq!(
            unsafe { WaitForSingleObject(reader.thread, 0) },
            WAIT_TIMEOUT
        );
        // 调用方的通道接收端先没了，线程之后才读到 EOF。
        let mut reader = reader;
        drop(std::mem::replace(&mut reader.rx, sync_channel(1).1));
        drop(tx);
        assert!(thread_exited(&reader, Duration::from_secs(10)));
    }

    fn cmd_exe() -> std::path::PathBuf {
        let root = std::env::var_os("SystemRoot").expect("SystemRoot");
        Path::new(&root).join("System32").join("cmd.exe")
    }

    /// 宿主从创建起就在 job 里，stdout 经管道读回、退出码可取。
    #[test]
    fn spawned_process_is_in_the_job_and_pipes_stdout() {
        let job = Job::new().expect("job");
        let cmd = cmd_exe();
        let args = [
            OsStr::new("/d"),
            OsStr::new("/c"),
            OsStr::new("echo fushi_job"),
        ];
        let (child, mut stdout) =
            spawn_in_job(&cmd, &args, &std::env::temp_dir(), &job).expect("spawn");
        let mut in_job = BOOL(0);
        // SAFETY: 两个句柄都有效；in_job 在调用期间存活。
        unsafe {
            windows::Win32::System::JobObjects::IsProcessInJob(
                child.handle(),
                Some(job.0),
                &mut in_job,
            )
        }
        .expect("IsProcessInJob");
        assert!(in_job.as_bool(), "child must be in the job");
        let mut out = String::new();
        stdout.read_to_string(&mut out).expect("read stdout");
        assert_eq!(out.trim(), "fushi_job");
        assert!(child.wait(Duration::from_secs(10)));
        assert_eq!(child.exit_code().expect("exit code"), 0);
    }

    /// 入 job 失败时不许带着「无内存上限」继续跑：给一个不是 job 的句柄，创建必须整体失败。
    /// （旧实现 spawn 后再 `let _ = AssignProcessToJobObject(..)`，这里会成功拿到一个不受限
    /// 的进程。）
    #[test]
    fn spawn_fails_instead_of_running_outside_the_job() {
        let not_a_job = OpenOptions::new()
            .read(true)
            .write(true)
            .open("NUL")
            .expect("open NUL");
        let fake = std::mem::ManuallyDrop::new(Job(HANDLE(not_a_job.as_raw_handle())));
        let marker = std::env::temp_dir().join(format!(
            "fushi_shell_thumbs_no_job_{}.txt",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&marker);
        let cmd = cmd_exe();
        let args = [
            OsStr::new("/d"),
            OsStr::new("/c"),
            OsStr::new("echo"),
            OsStr::new("ran>"),
            marker.as_os_str(),
        ];
        let result = spawn_in_job(&cmd, &args, &std::env::temp_dir(), &fake);
        if let Ok((child, _)) = &result {
            child.wait(Duration::from_secs(10));
        }
        let ran = marker.exists();
        let _ = std::fs::remove_file(&marker);
        assert!(
            result.is_err(),
            "spawn must fail when the job cannot be applied"
        );
        assert!(!ran, "the process must never have run");
    }

    /// 命令行按 `CommandLineToArgvW` 的规则往返（空格、引号、结尾反斜杠、空参数）。
    #[test]
    fn command_line_round_trips_through_command_line_to_argv() {
        use windows::Win32::Foundation::{HLOCAL, LocalFree};
        use windows::Win32::UI::Shell::CommandLineToArgvW;

        let args: Vec<&OsStr> = [
            "256",
            r"C:\Books\My Manga\vol 1.cbz",
            r#"a"b"#,
            r"C:\dir with space\",
            r#"back\\"slash"#,
            "",
            "plain",
        ]
        .iter()
        .map(OsStr::new)
        .collect();
        let exe = Path::new(r"C:\Program Files\Fushi\fushi_shell_thumbs_host.exe");
        let mut cmd = command_line(exe, &args);
        cmd.push(0);
        let mut argc = 0i32;
        // SAFETY: cmd 以 NUL 结尾；返回数组用 LocalFree 释放。
        let argv = unsafe { CommandLineToArgvW(PCWSTR(cmd.as_ptr()), &mut argc) };
        assert!(!argv.is_null());
        // SAFETY: argv 指向 argc 个以 NUL 结尾的宽字符串。
        let parsed: Vec<String> = unsafe {
            (0..argc as usize)
                .map(|i| (*argv.add(i)).to_string().expect("utf-16"))
                .collect()
        };
        // SAFETY: argv 由 CommandLineToArgvW 分配，只释放一次。
        unsafe { LocalFree(Some(HLOCAL(argv.cast()))) };
        let mut expected = vec![exe.to_str().unwrap().to_owned()];
        expected.extend(args.iter().map(|a| a.to_str().unwrap().to_owned()));
        assert_eq!(parsed, expected);
    }

    /// 名额用满后新的请求排队，到点仍没名额就放弃；名额一归还，排队者立刻拿到。
    #[test]
    fn host_slots_bound_concurrency() {
        static SLOTS: HostSlots = HostSlots::new(2);
        let a = SLOTS.acquire(Instant::now()).expect("slot a");
        let b = SLOTS.acquire(Instant::now()).expect("slot b");
        assert!(
            SLOTS
                .acquire(Instant::now() + Duration::from_millis(50))
                .is_none(),
            "third concurrent host must not start"
        );
        let waiter = std::thread::spawn(|| {
            SLOTS
                .acquire(Instant::now() + Duration::from_secs(30))
                .map(|slot| {
                    drop(slot);
                })
                .is_some()
        });
        drop(a);
        assert!(
            waiter.join().expect("waiter"),
            "freed slot must wake a waiter"
        );
        drop(b);
        assert_eq!(*SLOTS.lock(), 0);
    }
}
