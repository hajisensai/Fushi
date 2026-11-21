//! 安装器注册与 crate 之间的契约：CLSID、注册视图、隔离开关、挂载点、随包位置都要对得上。
//! 任何一处漂移，资源管理器都只会静默退回图标，所以这里逐条钉住。

use std::path::PathBuf;

fn repo_file(rel: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

fn iss() -> String {
    repo_file("fushi/windows/installer/fushi.iss")
}

/// `#define Name "value"` 的值。
fn define(src: &str, name: &str) -> String {
    let prefix = format!("#define {name} \"");
    let line = src
        .lines()
        .find(|l| l.trim_start().starts_with(&prefix))
        .unwrap_or_else(|| panic!("fushi.iss has no #define {name}"));
    let rest = &line.trim_start()[prefix.len()..];
    rest[..rest.rfind('"').unwrap()].to_string()
}

#[test]
fn installer_clsid_matches_the_crate() {
    // Inno 里 `{{` 是转义的单个 `{`。
    let clsid = define(&iss(), "FushiThumbClsid").replacen("{{", "{", 1);
    assert_eq!(clsid, fushi_shell_thumbs::THUMBNAIL_PROVIDER_CLSID);
    let slot = define(&iss(), "ThumbnailShellExKey").replacen("{{", "{", 1);
    assert_eq!(slot, "ShellEx\\{e357fccd-a995-4576-b01f-234630154e96}");
}

fn registry_lines(src: &str) -> Vec<&str> {
    src.lines()
        .filter(|l| l.starts_with("Root:") && l.contains("FushiThumbClsid"))
        .collect()
}

#[test]
fn com_server_is_registered_in_the_64_bit_per_user_view_with_isolation_disabled() {
    let src = iss();
    let lines = registry_lines(&src);
    assert!(!lines.is_empty());
    for l in &lines {
        // 32 位安装器写 HKCU\Software\Classes\CLSID 会被重定向进 Wow6432Node。
        assert!(l.starts_with("Root: HKCU64;"), "not HKCU64: {l}");
        assert!(l.contains("Tasks: bookassoc"), "not tied to bookassoc: {l}");
    }
    let has = |needle: &[&str]| lines.iter().any(|l| needle.iter().all(|n| l.contains(n)));
    assert!(has(&[
        "CLSID\\{#FushiThumbClsid}\\InprocServer32\"",
        "ValueData: \"{app}\\fushi_shell_thumbs.dll\""
    ]));
    assert!(has(&[
        "InprocServer32\"",
        "ValueName: \"ThreadingModel\"",
        "ValueData: \"Apartment\""
    ]));
    // HKCU 注册的处理器进不了系统隔离进程（见 src/win/host_client.rs），必须进程内。
    assert!(has(&[
        "CLSID\\{#FushiThumbClsid}\"",
        "ValueType: dword",
        "ValueName: \"DisableProcessIsolation\"",
        "ValueData: 1"
    ]));
}

#[test]
fn handler_is_attached_to_fushi_book_and_free_extension_slots() {
    let src = iss();
    let lines = registry_lines(&src);
    assert!(lines.iter().any(|l| l.contains(
        "Subkey: \"Software\\Classes\\Fushi.Book\\{#ThumbnailShellExKey}\"; ValueType: string; ValueData: \"{#FushiThumbClsid}\""
    )));
    for ext in [".epub", ".cbz", ".cbr", ".cb7", ".pdf"] {
        let key = format!("SystemFileAssociations\\{ext}\\{{#ThumbnailShellExKey}}\"");
        let line = lines
            .iter()
            .find(|l| l.contains(&key))
            .unwrap_or_else(|| panic!("no fallback registration for {ext}"));
        assert!(
            line.contains(&format!("Check: FushiThumbnailSlotFree('{ext}')")),
            "{ext} fallback must not overwrite another thumbnail handler: {line}"
        );
        assert!(line.contains("Flags: uninsdeletekey"), "{line}");
    }
    assert!(src.contains("function FushiThumbnailSlotFree(const Ext: String): Boolean;"));
    assert!(src.contains("ChangesAssociations=yes"));
}

#[test]
fn locked_handler_is_set_aside_before_files_are_copied() {
    let src = iss();
    assert!(src.contains("procedure FushiSetAsideThumbnailHandler();"));
    let step = &src[src
        .find("procedure CurStepChanged(CurStep: TSetupStep);")
        .unwrap()..];
    let set_aside = step.find("FushiSetAsideThumbnailHandler();").unwrap();
    let post_install = step.find("if CurStep <> ssPostInstall then").unwrap();
    assert!(set_aside < post_install, "rename must happen at ssInstall");
    assert!(src.contains("Type: files; Name: \"{app}\\fushi_shell_thumbs.dll.*.old\""));
}

#[test]
fn release_workflow_bundles_both_artifacts_beside_their_dependencies() {
    let wf = repo_file(".github/workflows/release-desktop.yml");
    let step = &wf[wf
        .find("- name: Build and bundle fushi_shell_thumbs")
        .expect("release-desktop.yml bundles fushi_shell_thumbs")..];
    assert!(step.contains("native/fushi_shell_thumbs/build_windows_dll.ps1 -InstallDirectory"));
    for name in [
        "'fushi_shell_thumbs.dll'",
        "'fushi_shell_thumbs_host.exe'",
        "'7za\\7z.dll'",
        "'pdfium.dll'",
    ] {
        assert!(step.contains(name), "release step does not verify {name}");
    }
    // 必须在签名之前放进 Release 目录（签名步骤递归签整个目录）。
    let sign = wf.find("- name: Sign Windows bundle binaries").unwrap();
    let bundle = wf
        .find("- name: Build and bundle fushi_shell_thumbs")
        .unwrap();
    assert!(bundle < sign);
    let script = repo_file("native/fushi_shell_thumbs/build_windows_dll.ps1");
    assert!(script.contains("\"fushi_shell_thumbs.dll\", \"fushi_shell_thumbs_host.exe\""));
}

#[cfg(windows)]
#[test]
fn crate_constants_match_the_bundle_layout() {
    assert_eq!(
        fushi_shell_thumbs::win::host_client::HOST_EXE,
        "fushi_shell_thumbs_host.exe"
    );
    assert_eq!(
        fushi_shell_thumbs::win::sevenzip::SEVEN_ZIP_DLL,
        "7za\\7z.dll"
    );
}
