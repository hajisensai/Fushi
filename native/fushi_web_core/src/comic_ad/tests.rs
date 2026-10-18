use std::path::PathBuf;

use serde_json::Value;

use super::*;

fn vectors_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/vectors/comic_ad")
}

fn expected() -> Value {
    let raw = std::fs::read(vectors_dir().join("expected.json")).expect("expected.json");
    serde_json::from_slice(&raw).expect("valid json")
}

/// 回归向量：旧 Dart 实现对 36 张输入的结论（两张记录了已修的 Dart bug，见 note）。
#[test]
fn regression_vectors_match() {
    let v = expected();
    let tolerance = v["colorfulTolerance"].as_f64().unwrap();
    let rules = ComicAdRules::default();
    let cases = v["cases"].as_array().unwrap();
    assert!(cases.len() >= 30, "vector set collapsed: {}", cases.len());
    let mut failures = Vec::new();
    for case in cases {
        let file = case["file"].as_str().unwrap();
        let bytes = std::fs::read(vectors_dir().join("inputs").join(file)).unwrap();
        assert_eq!(
            bytes.len() as u64,
            case["bytes"].as_u64().unwrap(),
            "{file} changed on disk"
        );
        let got = analyze(&bytes, &rules);
        let want_ad = case["expectedIsAd"].as_bool().unwrap();
        if (got.verdict == ComicAdVerdict::Ad) != want_ad {
            failures.push(format!("{file}: isAd={:?} want {want_ad}", got.verdict));
        }
        match (case["expectedColorful"].as_f64(), got.colorful) {
            (None, None) => {}
            (Some(want), Some(have)) if (want - have).abs() <= tolerance => {}
            (want, have) => failures.push(format!("{file}: colorful={have:?} want {want:?}")),
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn candidate_ranges_match_dart() {
    let v = expected();
    let rules = ComicAdRules::default();
    for (n, want) in v["candidates"].as_object().unwrap() {
        let n: u32 = n.parse().unwrap();
        let want: Vec<u32> = want
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_u64().unwrap() as u32)
            .collect();
        let got: Vec<u32> = (candidate_start(n, &rules)..n).collect();
        assert_eq!(got, want, "page count {n}");
    }
}

#[test]
fn rules_defaults_match_recorded_dart_constants() {
    let v = expected();
    let r = ComicAdRules::default();
    assert_eq!(
        r.tail_window as u64,
        v["rules"]["tailWindow"].as_u64().unwrap()
    );
    assert_eq!(
        r.protected_leading_pages as u64,
        v["rules"]["protectedLeadingPages"].as_u64().unwrap()
    );
    assert_eq!(
        r.colorful_threshold,
        v["rules"]["colorfulThreshold"].as_f64().unwrap()
    );
}

/// 批量接口与逐张接口结论一致（并行路径不串位）。
#[test]
fn batch_equals_single() {
    let v = expected();
    let rules = ComicAdRules::default();
    let files: Vec<Vec<u8>> = v["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| {
            std::fs::read(
                vectors_dir()
                    .join("inputs")
                    .join(c["file"].as_str().unwrap()),
            )
            .unwrap()
        })
        .collect();
    let slices: Vec<&[u8]> = files.iter().map(Vec::as_slice).collect();
    let batch = detect_batch(&slices, &rules);
    for (i, bytes) in slices.iter().enumerate() {
        assert_eq!(batch[i], analyze(bytes, &rules).verdict, "index {i}");
    }
}

#[test]
fn c_abi_batch_roundtrip() {
    let ad = std::fs::read(vectors_dir().join("inputs/t_poster_qr_600x900.png")).unwrap();
    let page = std::fs::read(vectors_dir().join("inputs/py_manga_page_800x1200.jpg")).unwrap();
    let garbage = [1u8, 2, 3];
    let ptrs = [
        ad.as_ptr(),
        page.as_ptr(),
        garbage.as_ptr(),
        std::ptr::null(),
    ];
    let lens = [ad.len(), page.len(), garbage.len(), 0];
    let mut out = [9u8; 4];
    let rules = ffi::fwc_comic_ad_default_rules();
    let rc = unsafe {
        ffi::fwc_comic_ad_detect_batch(&rules, ptrs.as_ptr(), lens.as_ptr(), 4, out.as_mut_ptr())
    };
    assert_eq!(rc, 0);
    assert_eq!(out, [1, 0, 2, 2]);
    assert_eq!(
        unsafe { ffi::fwc_comic_ad_candidate_start(12, std::ptr::null()) },
        3
    );
    assert_eq!(unsafe { ffi::fwc_comic_ad_candidate_start(30, &rules) }, 20);
    assert_eq!(unsafe { ffi::fwc_comic_ad_candidate_start(2, &rules) }, 2);
}
