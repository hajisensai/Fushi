//! 诊断：对真实文件走宿主进程的同一条取封面路径，把结果存成 PNG 看一眼。
//!
//! ```text
//! cargo run --profile quick --example probe -- <依赖目录(含 7z.dll / pdfium.dll)> <输出目录> <文件...>
//! ```
//! 每个文件打印 `OK 宽x高 路径` 或 `FAIL 原因 路径`。
#[cfg(windows)]
fn main() {
    use fushi_shell_thumbs::win::{set_dependency_dir, thumbnail_for_path};

    let mut args = std::env::args_os().skip(1);
    let deps = args.next().expect("deps dir");
    let out_dir = std::path::PathBuf::from(args.next().expect("output dir"));
    set_dependency_dir(deps.into());
    std::fs::create_dir_all(&out_dir).unwrap();
    for (i, file) in args.enumerate() {
        let path = std::path::PathBuf::from(file);
        match thumbnail_for_path(&path, 256) {
            Ok(t) => {
                let rgba: Vec<u8> = t
                    .bgra
                    .chunks_exact(4)
                    .flat_map(|p| [p[2], p[1], p[0], p[3]])
                    .collect();
                let img = image::RgbaImage::from_raw(t.width, t.height, rgba).unwrap();
                img.save(out_dir.join(format!("{i:03}.png"))).unwrap();
                println!("OK {}x{} {}", t.width, t.height, path.display());
            }
            Err(e) => println!("FAIL {e} {}", path.display()),
        }
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("probe only runs on Windows");
}
