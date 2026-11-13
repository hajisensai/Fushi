//! 换代干跑的命令行入口（设计 §8 G4）：对一份协议 3 的 srs.db 只读地走一遍迁移的前五步，把报告写成 JSON。
//! 取代设计稿附录 A 的 Python 试算。实现在 `fushi_fsrs::store::gen4::dryrun`，app 里的预演（G4b）调的是同一个函数。
//!
//! ```text
//! cargo run --release --example gen4_dryrun -- --old <srs.db> --work <目录> [--caches <CacheConfig JSON 文件>]
//!     [--out <报告.json>] [--keep] [--full-examples] [--examples <N>] [--batch <N>]
//! ```
//!
//! - `--caches`：app 交给旧内核的缓存配置（默认牌组、内置笔记类型的代码默认值）。文件里是一个配置就用于所有
//!   profile；是 `{ "<profile uid>": 配置, … }` 就按 profile 取。不给只有默认牌组（内置类型的笔记行会对不上）。
//! - `--keep`：留下临时新库（`<目录>/gen4-dryrun.db`）供排查；默认跑完删掉。
//! - `--full-examples`：差异的例子给整行（含笔记内容）；默认只给 ID。
//!
//! 退出码：0 = `pass`，1 = 其余结论（报告照写），2 = 跑不起来。

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

use fushi_fsrs::store::gen4::dryrun::{DEFAULT_EXAMPLES, Options, Stop, run};
use serde_json::Value;

fn usage() -> ! {
    eprintln!(
        "usage: gen4_dryrun --old <srs.db> --work <dir> [--caches <file>] [--out <file>] [--keep] \
         [--full-examples] [--examples <n>] [--batch <n>]"
    );
    std::process::exit(2);
}

fn main() {
    let mut args = std::env::args().skip(1);
    let (mut old, mut work, mut caches, mut out) = (None, None, None, None);
    let (mut keep, mut full, mut examples, mut batch) = (false, false, DEFAULT_EXAMPLES, 20_000u64);
    while let Some(a) = args.next() {
        let mut value = || args.next().unwrap_or_else(|| usage());
        match a.as_str() {
            "--old" => old = Some(PathBuf::from(value())),
            "--work" => work = Some(PathBuf::from(value())),
            "--caches" => caches = Some(PathBuf::from(value())),
            "--out" => out = Some(PathBuf::from(value())),
            "--keep" => keep = true,
            "--full-examples" => full = true,
            "--examples" => examples = value().parse().unwrap_or_else(|_| usage()),
            "--batch" => batch = value().parse().unwrap_or_else(|_| usage()),
            _ => usage(),
        }
    }
    let (Some(old), Some(work)) = (old, work) else {
        usage()
    };
    let caches: BTreeMap<String, String> = match caches {
        None => BTreeMap::new(),
        Some(p) => {
            let text = std::fs::read_to_string(&p).unwrap_or_else(|e| {
                eprintln!("{}: {e}", p.display());
                std::process::exit(2);
            });
            let v: Value = serde_json::from_str(&text).unwrap_or_else(|e| {
                eprintln!("{}: {e}", p.display());
                std::process::exit(2);
            });
            // 一个配置（有 `defaultDeck`）用于全部 profile：用通配键，run 之前按库里的 profile 展开。
            if v.get("defaultDeck").is_some() {
                BTreeMap::from([("*".to_owned(), text)])
            } else {
                v.as_object()
                    .map(|m| m.iter().map(|(k, c)| (k.clone(), c.to_string())).collect())
                    .unwrap_or_default()
            }
        }
    };
    let caches = match caches.get("*") {
        Some(one) => {
            let profiles = fushi_fsrs::store::gen4::dryrun::open_legacy(&old)
                .and_then(|c| fushi_fsrs::store::gen4::legacy::profiles(&c))
                .unwrap_or_else(|e| {
                    eprintln!("{e}");
                    std::process::exit(2);
                });
            profiles.into_iter().map(|p| (p, one.clone())).collect()
        }
        None => caches,
    };
    let stop = Stop::new();
    let started = Instant::now();
    let mut progress = |stage: &str, profile: Option<&str>| {
        eprintln!(
            "[{:>7.1}s] {stage} {}",
            started.elapsed().as_secs_f64(),
            profile.unwrap_or("")
        );
    };
    let report = run(
        &old,
        &work,
        Options {
            caches: &caches,
            batch,
            keep,
            examples,
            full_examples: full,
            stop: &stop,
            progress: &mut progress,
        },
    )
    .unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(2);
    });
    let text = serde_json::to_string_pretty(&report).expect("json");
    match out {
        Some(p) => std::fs::write(&p, &text).unwrap_or_else(|e| {
            eprintln!("{}: {e}", p.display());
            std::process::exit(2);
        }),
        None => println!("{text}"),
    }
    eprintln!("verdict: {}", report["verdict"]);
    std::process::exit(if report["verdict"] == "pass" { 0 } else { 1 });
}
