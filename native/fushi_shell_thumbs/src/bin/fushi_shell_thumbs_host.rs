//! 缩略图宿主进程：资源管理器里的 `fushi_shell_thumbs.dll` 每张缩略图拉起一次。
//!
//! 用法：`fushi_shell_thumbs_host.exe <边长> <文件路径>`；成功时 stdout 写一帧
//! （格式见 `fushi_shell_thumbs::wire`）、退出码 0，失败退出码 1、stdout 为空。
//! GUI 子系统：被拉起时不闪控制台窗口（stdout 仍走父进程给的管道）。
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
fn main() -> std::process::ExitCode {
    use std::io::Write;
    use std::process::ExitCode;

    let mut args = std::env::args_os().skip(1);
    let (Some(cx), Some(path), None) = (args.next(), args.next(), args.next()) else {
        return ExitCode::from(2);
    };
    let Some(cx) = cx.to_str().and_then(|s| s.parse::<u32>().ok()) else {
        return ExitCode::from(2);
    };
    let cx = cx.clamp(1, fushi_shell_thumbs::wire::MAX_EDGE);
    match fushi_shell_thumbs::win::thumbnail_for_path(std::path::Path::new(&path), cx) {
        Ok(t) => {
            let frame = fushi_shell_thumbs::wire::encode(&t);
            let mut out = std::io::stdout().lock();
            if out.write_all(&frame).and_then(|_| out.flush()).is_ok() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Err(_) => ExitCode::FAILURE,
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("fushi_shell_thumbs_host only runs on Windows");
}
