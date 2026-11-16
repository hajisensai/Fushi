//! 资源管理器进程里的一侧：把一个文件交给宿主进程 `fushi_shell_thumbs_host.exe` 解析，
//! 带超时、内存上限地取回缩略图。
//!
//! 为什么不在资源管理器进程里直接解析：本处理器按用户安装（HKCU），实测（2026-11-16，
//! Windows 11）系统的缩略图隔离进程（COM Surrogate，AppID `{AB8902B4-…}`）激活不到 HKCU 里
//! 注册的 CLSID（`REGDB_E_CLASSNOTREG`），只能 `DisableProcessIsolation=1` 进程内加载。于是隔离
//! 由我们自己做：解析不可信文件（zip / 7z.dll / pdfium.dll）全在一次性的子进程里，崩溃、卡死、
//! 吃内存都只丢这一张缩略图，拖不垮 explorer.exe。

use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOB_OBJECT_LIMIT_PROCESS_MEMORY,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject,
};
use windows::Win32::System::Threading::WaitForSingleObject;

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
    let stdout = child.stdout.take().expect("stdout is piped");
    let reader = std::thread::spawn(move || wire::read_frame(stdout, cx));

    let process = HANDLE(child.as_raw_handle());
    // SAFETY: process 是 child 持有的有效进程句柄。
    let waited = unsafe { WaitForSingleObject(process, TIMEOUT.as_millis() as u32) };
    if waited != WAIT_OBJECT_0 {
        let _ = child.kill();
        let _ = child.wait();
        // 不 join 读线程：子进程已死、管道随之关闭，它会自己读到 EOF 退出。
        return Err(ThumbError::Io("thumbnail host timed out".into()));
    }
    let status = child.wait()?;
    drop(job);
    if !status.success() {
        return Err(ThumbError::Corrupt(format!(
            "thumbnail host exited with {status}"
        )));
    }
    reader
        .join()
        .map_err(|_| ThumbError::Io("reader thread panicked".into()))?
}
