use std::fs::File;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use aidoku::{Chapter, FilterValue, Manga};
use aidoku_test_runner::libs::StoreItem;
use aidoku_test_runner::{WasmEnv, imports};
use anyhow::{Context, Result, anyhow, bail};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use wasmer::{Function, FunctionEnv, FunctionEnvMut, Instance, Module, Store, TypedFunction};
use zip::ZipArchive;

const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
const MAX_WASM_BYTES: u64 = 64 * 1024 * 1024;

/// Host-side mirror of aidoku-rs' serialized search result. The upstream type
/// deliberately only implements `Serialize` because sources only send it out;
/// a runner needs this matching `Deserialize` representation.
#[derive(Debug, Deserialize, Serialize)]
struct SearchPageResult {
    entries: Vec<Manga>,
    has_next_page: bool,
}

#[derive(Debug, Deserialize, Serialize)]
enum HostPageContent {
    Url(String, Option<std::collections::HashMap<String, String>>),
    Text(String),
    Image(i32),
    Zip(String, String),
}

#[derive(Debug, Deserialize, Serialize)]
struct HostPage {
    content: HostPageContent,
    thumbnail: Option<String>,
    has_description: bool,
    description: Option<String>,
}

#[derive(Debug)]
struct AixPackage {
    path: PathBuf,
    manifest: Value,
    wasm: Vec<u8>,
}

impl AixPackage {
    fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let file = File::open(path)
            .with_context(|| format!("failed to open Aidoku package {}", path.display()))?;
        let mut archive = ZipArchive::new(file).context("invalid Aidoku .aix zip container")?;
        let manifest_bytes = read_entry(&mut archive, "Payload/source.json", MAX_MANIFEST_BYTES)?;
        let wasm = read_entry(&mut archive, "Payload/main.wasm", MAX_WASM_BYTES)?;
        if !wasm.starts_with(b"\0asm") {
            bail!("Payload/main.wasm does not have a WebAssembly header");
        }
        let manifest: Value =
            serde_json::from_slice(&manifest_bytes).context("invalid Payload/source.json")?;
        validate_manifest(&manifest)?;
        Ok(Self {
            path: path.to_path_buf(),
            manifest,
            wasm,
        })
    }
}

fn read_entry<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
    max_bytes: u64,
) -> Result<Vec<u8>> {
    let entry = archive
        .by_name(name)
        .with_context(|| format!("Aidoku package is missing {name}"))?;
    if entry.size() > max_bytes {
        bail!("{name} exceeds the {max_bytes}-byte safety limit");
    }
    let mut bytes = Vec::with_capacity(entry.size() as usize);
    entry
        .take(max_bytes + 1)
        .read_to_end(&mut bytes)
        .with_context(|| format!("failed to read {name}"))?;
    if bytes.len() as u64 > max_bytes {
        bail!("{name} exceeds the {max_bytes}-byte safety limit");
    }
    Ok(bytes)
}

fn validate_manifest(manifest: &Value) -> Result<()> {
    let info = manifest
        .get("info")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("source manifest is missing the info object"))?;
    for key in ["id", "name"] {
        let value = info
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or_default();
        if value.is_empty() {
            bail!("source manifest info.{key} must be a non-empty string");
        }
    }
    if info.get("version").and_then(Value::as_u64).is_none() {
        bail!("source manifest info.version must be a non-negative integer");
    }
    Ok(())
}

struct AidokuRuntime {
    store: Store,
    environment: FunctionEnv<WasmEnv>,
    instance: Instance,
    module: Module,
}

fn host_std_abort(mut environment: FunctionEnvMut<WasmEnv>) {
    environment
        .data_mut()
        .write_stdout("error: Aidoku source aborted.\n");
}

fn host_std_print(mut environment: FunctionEnvMut<WasmEnv>, pointer: u32, length: u32) {
    let message = environment
        .data()
        .read_string(&environment, pointer, length);
    match message {
        Ok(message) => {
            environment.data_mut().write_stdout(&message);
            environment.data_mut().write_stdout("\n");
        }
        Err(_) => environment
            .data_mut()
            .write_stdout("error: failed to read Aidoku source log message.\n"),
    }
}

impl AidokuRuntime {
    fn load(wasm: &[u8]) -> Result<Self> {
        let mut store = Store::default();
        let module = Module::new(&store, wasm).context("failed to compile Aidoku WebAssembly")?;
        let environment = FunctionEnv::new(&mut store, WasmEnv::new());
        let mut import_object = imports::generate_imports(&mut store, &environment);
        // aidoku-rs' panic handler imports these from `std`, while the current
        // MIT test runner only registers the normal logging functions in
        // `env`. Supplying both namespaces matches the source ABI.
        import_object.define(
            "std",
            "abort",
            Function::new_typed_with_env(&mut store, &environment, host_std_abort),
        );
        import_object.define(
            "std",
            "print",
            Function::new_typed_with_env(&mut store, &environment, host_std_print),
        );
        let instance = Instance::new(&mut store, &module, &import_object)
            .context("failed to instantiate Aidoku WebAssembly")?;
        let memory = instance
            .exports
            .get_memory("memory")
            .context("Aidoku source does not export memory")?
            .clone();
        environment.as_mut(&mut store).memory = Some(memory);

        let start: TypedFunction<(), ()> = instance
            .exports
            .get_typed_function(&store, "start")
            .context("Aidoku source does not export start")?;
        start
            .call(&mut store)
            .context("Aidoku source start function failed")?;

        Ok(Self {
            store,
            environment,
            instance,
            module,
        })
    }

    fn capabilities(&self) -> Value {
        let imports = self
            .module
            .imports()
            .map(|item| format!("{}.{}", item.module(), item.name()))
            .collect::<Vec<_>>();
        let exports = self
            .module
            .exports()
            .map(|item| item.name().to_owned())
            .collect::<Vec<_>>();
        json!({
            "imports": imports,
            "exports": exports,
            "requiresWebView": imports.iter().any(|name| name.starts_with("js.webview_")),
        })
    }

    fn take_result<T: DeserializeOwned>(&mut self, result_pointer: i32) -> Result<T> {
        if result_pointer <= 0 {
            let source_log = self.environment.as_ref(&self.store).stdout.trim();
            let suffix = if source_log.is_empty() {
                String::new()
            } else {
                format!(": {source_log}")
            };
            bail!("Aidoku source returned error code {result_pointer}{suffix}");
        }

        let result_header = self
            .environment
            .as_ref(&self.store)
            .read_u32(&self.store, result_pointer as u32)
            .context("failed to read Aidoku result header")? as i32;
        let source_error = if result_header == -1 {
            let result_length = self
                .environment
                .as_ref(&self.store)
                .read_u32(&self.store, result_pointer as u32 + 8)
                .context("failed to read Aidoku error length")?;
            if result_length < 12 {
                Some("Aidoku source returned a malformed error".to_owned())
            } else {
                Some(
                    self.environment
                        .as_ref(&self.store)
                        .read_string(&self.store, result_pointer as u32 + 12, result_length - 12)
                        .context("failed to read Aidoku source error")?,
                )
            }
        } else {
            None
        };
        let bytes = if source_error.is_none() {
            Some(
                self.environment
                    .as_ref(&self.store)
                    .read_item_bytes(&self.store, result_pointer as u32)
                    .context("failed to read Aidoku result")?,
            )
        } else {
            None
        };

        let free_result: TypedFunction<i32, ()> = self
            .instance
            .exports
            .get_typed_function(&self.store, "free_result")
            .context("Aidoku source does not export free_result")?;
        free_result
            .call(&mut self.store, result_pointer)
            .context("Aidoku source failed to free its result")?;

        if let Some(error) = source_error {
            bail!("Aidoku source error: {error}");
        }
        let bytes = bytes.ok_or_else(|| anyhow!("Aidoku source returned no result bytes"))?;
        postcard::from_bytes(&bytes).context("failed to decode Aidoku result")
    }

    fn search(&mut self, query: Option<&str>, page: i32) -> Result<SearchPageResult> {
        if page < 1 {
            bail!("search page must be at least 1");
        }
        let query_descriptor = query
            .filter(|value| !value.is_empty())
            .map(|value| {
                self.environment
                    .as_mut(&mut self.store)
                    .store
                    .store(StoreItem::String(value.to_owned()))
            })
            .unwrap_or(-1);
        let filters_descriptor = self
            .environment
            .as_mut(&mut self.store)
            .store
            .store_encoded(&Vec::<FilterValue>::new())
            .context("failed to encode empty Aidoku filters")?;

        let search: TypedFunction<(i32, i32, i32), i32> = self
            .instance
            .exports
            .get_typed_function(&self.store, "get_search_manga_list")
            .context("Aidoku source does not export get_search_manga_list")?;
        let result_pointer = search
            .call(&mut self.store, query_descriptor, page, filters_descriptor)
            .context("Aidoku search function trapped")?;

        if query_descriptor > 0 {
            self.environment
                .as_mut(&mut self.store)
                .store
                .remove(query_descriptor);
        }
        self.environment
            .as_mut(&mut self.store)
            .store
            .remove(filters_descriptor);

        self.take_result(result_pointer)
    }

    fn details(&mut self, manga: &Manga) -> Result<Manga> {
        let manga_descriptor = self
            .environment
            .as_mut(&mut self.store)
            .store
            .store_encoded(manga)
            .context("failed to encode Aidoku manga")?;
        let details: TypedFunction<(i32, i32, i32), i32> = self
            .instance
            .exports
            .get_typed_function(&self.store, "get_manga_update")
            .context("Aidoku source does not export get_manga_update")?;
        let result_pointer = details
            .call(&mut self.store, manga_descriptor, 1, 1)
            .context("Aidoku manga update function trapped")?;
        self.environment
            .as_mut(&mut self.store)
            .store
            .remove(manga_descriptor);
        self.take_result(result_pointer)
    }

    fn pages(&mut self, manga: &Manga, chapter: &Chapter) -> Result<Vec<HostPage>> {
        let manga_descriptor = self
            .environment
            .as_mut(&mut self.store)
            .store
            .store_encoded(manga)
            .context("failed to encode Aidoku manga")?;
        let chapter_descriptor = self
            .environment
            .as_mut(&mut self.store)
            .store
            .store_encoded(chapter)
            .context("failed to encode Aidoku chapter")?;
        let pages: TypedFunction<(i32, i32), i32> = self
            .instance
            .exports
            .get_typed_function(&self.store, "get_page_list")
            .context("Aidoku source does not export get_page_list")?;
        let result_pointer = pages
            .call(&mut self.store, manga_descriptor, chapter_descriptor)
            .context("Aidoku page list function trapped")?;
        let environment = self.environment.as_mut(&mut self.store);
        environment.store.remove(manga_descriptor);
        environment.store.remove(chapter_descriptor);
        self.take_result(result_pointer)
    }
}

fn inspect(package: AixPackage) -> Result<Value> {
    let runtime = AidokuRuntime::load(&package.wasm)?;
    Ok(json!({
        "protocolVersion": 1,
        "packagePath": package.path,
        "manifest": package.manifest,
        "runtime": runtime.capabilities(),
    }))
}

fn search(package: AixPackage, query: Option<&str>, page: i32) -> Result<Value> {
    let mut runtime = AidokuRuntime::load(&package.wasm)?;
    let result = runtime.search(query, page)?;
    Ok(json!({
        "protocolVersion": 1,
        "source": package.manifest["info"].clone(),
        "result": serde_json::to_value(result).context("failed to encode search result as JSON")?,
    }))
}

fn details(package: AixPackage, manga_json: &str) -> Result<Value> {
    let manga: Manga = serde_json::from_str(manga_json).context("invalid manga JSON")?;
    let mut runtime = AidokuRuntime::load(&package.wasm)?;
    let result = runtime.details(&manga)?;
    Ok(json!({
        "protocolVersion": 1,
        "source": package.manifest["info"].clone(),
        "result": result,
    }))
}

fn pages(package: AixPackage, manga_json: &str, chapter_json: &str) -> Result<Value> {
    let manga: Manga = serde_json::from_str(manga_json).context("invalid manga JSON")?;
    let chapter: Chapter = serde_json::from_str(chapter_json).context("invalid chapter JSON")?;
    let mut runtime = AidokuRuntime::load(&package.wasm)?;
    let result = runtime.pages(&manga, &chapter)?;
    Ok(json!({
        "protocolVersion": 1,
        "source": package.manifest["info"].clone(),
        "result": result,
    }))
}

fn run() -> Result<Value> {
    let mut args = std::env::args().skip(1);
    let command = args.next().ok_or_else(|| {
        anyhow!("usage: fushi-aidoku-runtime <inspect|search|details|pages> PACKAGE.aix [ARGS...]")
    })?;
    let package_path = args
        .next()
        .ok_or_else(|| anyhow!("missing Aidoku package path"))?;
    let package = AixPackage::open(package_path)?;
    match command.as_str() {
        "inspect" => inspect(package),
        "search" => {
            let query = args.next();
            let page = args
                .next()
                .map(|value| value.parse::<i32>().context("invalid search page"))
                .transpose()?
                .unwrap_or(1);
            search(package, query.as_deref(), page)
        }
        "details" => {
            let manga_json = args.next().ok_or_else(|| anyhow!("missing manga JSON"))?;
            details(package, &manga_json)
        }
        "pages" => {
            let manga_json = args.next().ok_or_else(|| anyhow!("missing manga JSON"))?;
            let chapter_json = args.next().ok_or_else(|| anyhow!("missing chapter JSON"))?;
            pages(package, &manga_json, &chapter_json)
        }
        _ => bail!("unknown command {command:?}"),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(value) => match serde_json::to_string(&value) {
            Ok(output) => {
                println!("{output}");
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("{}", json!({"error": error.to_string()}));
                ExitCode::FAILURE
            }
        },
        Err(error) => {
            eprintln!("{}", json!({"error": format!("{error:#}")}));
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use tempfile::NamedTempFile;
    use zip::ZipWriter;
    use zip::write::SimpleFileOptions;

    use super::*;

    fn package_with(manifest: &str, wasm: &[u8]) -> NamedTempFile {
        let mut file = NamedTempFile::new().expect("create test package");
        {
            let mut archive = ZipWriter::new(file.as_file_mut());
            archive
                .start_file("Payload/source.json", SimpleFileOptions::default())
                .expect("start manifest entry");
            archive
                .write_all(manifest.as_bytes())
                .expect("write manifest");
            archive
                .start_file("Payload/main.wasm", SimpleFileOptions::default())
                .expect("start wasm entry");
            archive.write_all(wasm).expect("write wasm");
            archive.finish().expect("finish test package");
        }
        file
    }

    #[test]
    fn accepts_a_minimal_aix_container() {
        let file = package_with(
            r#"{"info":{"id":"ja.example","name":"Example","version":1}}"#,
            b"\0asm\x01\0\0\0",
        );
        let package = AixPackage::open(file.path()).expect("parse package");
        assert_eq!(package.manifest["info"]["id"], "ja.example");
        assert_eq!(package.wasm, b"\0asm\x01\0\0\0");
    }

    #[test]
    fn rejects_a_manifest_without_identity() {
        let file = package_with(
            r#"{"info":{"id":"ja.example","name":"","version":1}}"#,
            b"\0asm\x01\0\0\0",
        );
        let error = AixPackage::open(file.path()).expect_err("reject empty name");
        assert!(error.to_string().contains("info.name"));
    }

    #[test]
    fn rejects_a_non_wasm_payload() {
        let file = package_with(
            r#"{"info":{"id":"ja.example","name":"Example","version":1}}"#,
            b"not-wasm",
        );
        let error = AixPackage::open(file.path()).expect_err("reject non-wasm");
        assert!(error.to_string().contains("WebAssembly header"));
    }
}
