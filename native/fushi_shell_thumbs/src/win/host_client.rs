//! 资源管理器进程里的一侧：把一个文件交给宿主进程 `fushi_shell_thumbs_host.exe` 解析，
//! 带超时、内存上限地取回缩略图。
//!
//! 为什么不在资源管理器进程里直接解析：本处理器按用户安装（HKCU），实测（2026-11-16，
//! Windows 11）系统的缩略图隔离进程（COM Surrogate，AppID `{AB8902B4-…}`）激活不到 HKCU 里
//! 注册的 CLSID（`REGDB_E_CLASSNOTREG`），只能 `DisableProcessIsolation=1` 进程内加载。于是隔离
//! 由我们自己做：解析不可信文件（zip / 7z.dll / pdfium.dll）全在一次性的子进程里，崩溃、卡死、
//! 吃内存都只丢这一张缩略图，拖不垮 explorer.exe。

use std::ffi::c_void;
use std::io::Read;
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{CloseHandle, FreeLibrary, HANDLE, HMODULE, WAIT_OBJECT_0};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOB_OBJECT_LIMIT_PROCESS_MEMORY,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject,
};
use windows::Win32::System::LibraryLoader::{
    FreeLibraryAndExitThread, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, GetModuleHandleExW,
};
use windows::Win32::System::Threading::{CreateThread, THREAD_CREATION_FLAGS, WaitForSingleObject};
use windows::core::PCWSTR;

use crate::{ThumbError, Thumbnail, wire};

/// 宿主可执行文件名（与本 DLL 同目录，即 `{app}`）。
pub const HOST_EXE: &str = "fushi_shell_thumbs_host.exe";

/// 单张缩略图的总时限（含进程启动）。资源管理器自己也有超时，这里保证子进程一定被收走。
const TIMEOUT: Duration = Duration::from_secs(15);

/// 宿主进程的内存上限。
const MEMORY_LIMIT: usize = 1024 * 1024 * 1024;

/// 不降优先级（不加 BELOW_NORMAL_PRIORITY_CLASS）：缩略图是用户正盯着的前台工作。实测
/// （2026-11-16）机器满载时低优先级宿主会被饿到超时，约 1/12 的缩略图失败；普通优先级下
/// 84/84 成功。
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// 关闭时杀掉其中进程的 job（KILL_ON_JOB_CLOSE）。
struct Job(HANDLE);

impl Job {
    fn new() -> Option<Job> {
        // SAFETY: 匿名 job；limits 结构在调用期间存活。
        unsafe {
            let h = CreateJobObjectW(None, None).ok()?;
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
            .ok()?;
            Some(job)
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        // SAFETY: 句柄由 CreateJobObjectW 创建、只关一次。
        let _ = unsafe { CloseHandle(self.0) };
    }
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
    let job = Job::new();
    let mut child = Command::new(&host)
        .arg(cx.to_string())
        .arg(path)
        .current_dir(&dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()?;
    if let Some(job) = &job {
        // SAFETY: 两个句柄都有效；失败只是少了内存上限 / 连坐清理，超时 kill 仍兜底。
        let _ = unsafe { AssignProcessToJobObject(job.0, HANDLE(child.as_raw_handle())) };
    }

    // 宿主写满管道缓冲区就会阻塞，所以边跑边读。按帧头里的尺寸读够就停、不等 EOF：
    // 资源管理器里别的 CreateProcess 若恰好继承了管道写端，EOF 会迟到，但帧已经完整。
    // 读线程可能比本函数活得久（超时 / 宿主失败时不等它），见 [`spawn_frame_reader`]。
    let stdout = child.stdout.take().expect("stdout is piped");
    let reader = match spawn_frame_reader(stdout, cx) {
        Ok(reader) => reader,
        Err(e) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(e);
        }
    };

    let process = HANDLE(child.as_raw_handle());
    // SAFETY: process 是 child 持有的有效进程句柄。
    let waited = unsafe { WaitForSingleObject(process, TIMEOUT.as_millis() as u32) };
    if waited != WAIT_OBJECT_0 {
        let _ = child.kill();
        let _ = child.wait();
        return Err(ThumbError::Io("thumbnail host timed out".into()));
    }
    let status = child.wait()?;
    drop(job);
    if !status.success() {
        return Err(ThumbError::Corrupt(format!(
            "thumbnail host exited with {status}"
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
}
