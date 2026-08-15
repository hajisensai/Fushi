use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::fs::File;
use std::io::{Cursor, Read, Seek};
use std::path::{Path, PathBuf};

use aidoku::{Chapter, FilterValue, Listing, Manga};
use anyhow::{Context, Result, anyhow, bail};
use boa_engine::{Source, context::Context as JsContext};
use image::{DynamicImage, RgbaImage, imageops::FilterType};
use kuchiki::traits::*;
use kuchiki::{NodeData, NodeRef};
use reqwest::Method;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use wasmi::{Caller, Engine, Instance, Linker, Memory, Module, Store};
use zip::ZipArchive;

const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
const MAX_WASM_BYTES: u64 = 64 * 1024 * 1024;
const MAX_CANVAS_PIXELS: u64 = 64 * 1024 * 1024;
const DEFAULT_USER_AGENT: &str = "Aidoku/1 CFNetwork/3826.500.131 Darwin/24.5.0";

#[derive(Debug, Deserialize, Serialize)]
struct SearchPageResult {
    entries: Vec<Manga>,
    has_next_page: bool,
}

#[derive(Debug, Deserialize, Serialize)]
enum HostPageContent {
    Url(String, Option<HashMap<String, String>>),
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

#[derive(Debug, Serialize)]
struct ResolvedHostPage {
    #[serde(flatten)]
    page: HostPage,
    request_url: Option<String>,
    request_headers: HashMap<String, String>,
}

struct ResolvedImageRequest {
    url: String,
    headers: HashMap<String, String>,
}

struct AixPackage {
    path: PathBuf,
    manifest: Value,
    wasm: Vec<u8>,
    defaults: HashMap<String, Vec<u8>>,
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
        let settings = archive
            .by_name("Payload/settings.json")
            .ok()
            .and_then(|mut entry| {
                let mut bytes = Vec::new();
                entry.read_to_end(&mut bytes).ok()?;
                serde_json::from_slice::<Value>(&bytes).ok()
            });
        let defaults = package_defaults(&manifest, settings.as_ref())?;
        Ok(Self {
            path: path.to_path_buf(),
            manifest,
            wasm,
            defaults,
        })
    }
}

fn package_defaults(
    manifest: &Value,
    settings: Option<&Value>,
) -> Result<HashMap<String, Vec<u8>>> {
    fn visit(value: &Value, defaults: &mut HashMap<String, Vec<u8>>) -> Result<()> {
        match value {
            Value::Array(values) => {
                for value in values {
                    visit(value, defaults)?;
                }
            }
            Value::Object(object) => {
                if let (Some(key), Some(value)) = (
                    object.get("key").and_then(Value::as_str),
                    object.get("default"),
                ) {
                    let encoded = match value {
                        Value::Bool(value) => postcard::to_allocvec(value)?,
                        Value::Number(value) if value.is_i64() || value.is_u64() => {
                            postcard::to_allocvec(&(value.as_i64().unwrap_or_default() as i32))?
                        }
                        Value::Number(value) => {
                            postcard::to_allocvec(&(value.as_f64().unwrap_or_default() as f32))?
                        }
                        Value::String(value) => postcard::to_allocvec(value)?,
                        Value::Array(values) if values.iter().all(Value::is_string) => {
                            let values = values
                                .iter()
                                .filter_map(Value::as_str)
                                .map(str::to_owned)
                                .collect::<Vec<_>>();
                            postcard::to_allocvec(&values)?
                        }
                        Value::Null => Vec::new(),
                        _ => Vec::new(),
                    };
                    defaults.insert(key.to_owned(), encoded);
                }
                for value in object.values() {
                    visit(value, defaults)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    let mut defaults = HashMap::new();
    if let Some(settings) = settings {
        visit(settings, &mut defaults)?;
    }
    if !defaults.contains_key("languages") {
        let languages = manifest["info"]["languages"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>();
        let selected = languages
            .iter()
            .copied()
            .find(|language| *language == "en")
            .or_else(|| languages.first().copied())
            .map(str::to_owned)
            .into_iter()
            .collect::<Vec<_>>();
        defaults.insert("languages".to_owned(), postcard::to_allocvec(&selected)?);
    }
    if !defaults.contains_key("url") {
        let base_url = manifest["info"]["url"]
            .as_str()
            .or_else(|| manifest["info"]["urls"].as_array()?.first()?.as_str());
        if let Some(base_url) = base_url {
            defaults.insert("url".to_owned(), postcard::to_allocvec(base_url)?);
        }
    }
    Ok(defaults)
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
        if info
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or_default()
            .is_empty()
        {
            bail!("source manifest info.{key} must be a non-empty string");
        }
    }
    if info.get("version").and_then(Value::as_u64).is_none() {
        bail!("source manifest info.version must be a non-negative integer");
    }
    Ok(())
}

struct HtmlNode {
    node: NodeRef,
    base_url: Option<String>,
}

impl Clone for HtmlNode {
    fn clone(&self) -> Self {
        Self {
            node: self.node.clone(),
            base_url: self.base_url.clone(),
        }
    }
}

struct NetResponse {
    url: String,
    status: u16,
    headers: reqwest::header::HeaderMap,
    data: Vec<u8>,
}

struct NetRequest {
    method: Method,
    url: Option<String>,
    headers: reqwest::header::HeaderMap,
    body: Option<Vec<u8>>,
    timeout: Option<f64>,
    response: Option<NetResponse>,
}

#[derive(Clone)]
struct CanvasBitmap {
    image: RgbaImage,
}

enum StoreItem {
    String(String),
    Encoded(Vec<u8>),
    Request(Box<NetRequest>),
    Html(HtmlNode),
    HtmlList(Vec<HtmlNode>),
    Image(CanvasBitmap),
    Canvas(CanvasBitmap),
    JsContext(Box<JsContext>),
}

impl StoreItem {
    fn encoded(&self) -> Option<&[u8]> {
        match self {
            Self::String(value) => Some(value.as_bytes()),
            Self::Encoded(value) => Some(value),
            _ => None,
        }
    }
}

struct HostState {
    memory: Option<Memory>,
    descriptors: HashMap<i32, StoreItem>,
    next_descriptor: i32,
    stdout: String,
    partial_results: Vec<Vec<u8>>,
    defaults: HashMap<String, Vec<u8>>,
    /// Set when any network request during this invocation came back as a
    /// Cloudflare interstitial ("Just a moment…" / Turnstile challenge). A
    /// headless HTTP client cannot solve the JavaScript challenge, so the
    /// source parses the challenge HTML as its expected JSON/HTML payload and
    /// fails with an opaque decode error. Remembering that we saw the challenge
    /// lets us turn that opaque failure into an actionable `CLOUDFLARE_CHALLENGE`
    /// code instead of a raw `JsonParseError`.
    cloudflare_challenge: bool,
}

impl HostState {
    fn new(defaults: HashMap<String, Vec<u8>>) -> Self {
        Self {
            memory: None,
            descriptors: HashMap::new(),
            next_descriptor: 1,
            stdout: String::new(),
            partial_results: Vec::new(),
            defaults,
            cloudflare_challenge: false,
        }
    }

    fn store(&mut self, item: StoreItem) -> i32 {
        let descriptor = self.next_descriptor;
        self.descriptors.insert(descriptor, item);
        self.next_descriptor += 1;
        descriptor
    }

    fn store_encoded<T: Serialize>(&mut self, value: &T) -> Result<i32> {
        let bytes = postcard::to_allocvec(value).context("failed to encode Aidoku input")?;
        Ok(self.store(StoreItem::Encoded(bytes)))
    }

    fn remove(&mut self, descriptor: i32) {
        self.descriptors.remove(&descriptor);
        if self.descriptors.is_empty() {
            self.next_descriptor = 1;
        }
    }
}

fn memory(caller: &Caller<'_, HostState>) -> Result<Memory> {
    caller
        .data()
        .memory
        .ok_or_else(|| anyhow!("Aidoku source memory is not initialized"))
}

fn read_bytes(caller: &Caller<'_, HostState>, pointer: i32, length: i32) -> Result<Vec<u8>> {
    if pointer < 0 || length < 0 {
        bail!("negative WebAssembly memory range");
    }
    let mut bytes = vec![0; length as usize];
    memory(caller)?
        .read(caller, pointer as usize, &mut bytes)
        .context("failed to read WebAssembly memory")?;
    Ok(bytes)
}

fn read_string(caller: &Caller<'_, HostState>, pointer: i32, length: i32) -> Result<String> {
    String::from_utf8(read_bytes(caller, pointer, length)?)
        .context("Aidoku source returned invalid UTF-8")
}

fn write_bytes(caller: &mut Caller<'_, HostState>, pointer: i32, bytes: &[u8]) -> Result<()> {
    if pointer < 0 {
        bail!("negative WebAssembly memory pointer");
    }
    memory(caller)?
        .write(caller, pointer as usize, bytes)
        .context("failed to write WebAssembly memory")
}

fn read_u32(store: &Store<HostState>, memory: Memory, pointer: i32) -> Result<u32> {
    if pointer < 0 {
        bail!("negative WebAssembly result pointer");
    }
    let mut bytes = [0_u8; 4];
    memory
        .read(store, pointer as usize, &mut bytes)
        .context("failed to read Aidoku result header")?;
    Ok(u32::from_le_bytes(bytes))
}

fn parse_html(text: &str, base_url: Option<String>) -> HtmlNode {
    HtmlNode {
        node: kuchiki::parse_html().one(text),
        base_url,
    }
}

fn absolute_attribute(raw: String, base_url: Option<&str>) -> String {
    if reqwest::Url::parse(&raw).is_ok() {
        return raw;
    }
    base_url
        .and_then(|base| reqwest::Url::parse(base).ok())
        .and_then(|base| base.join(&raw).ok())
        .map(|url| url.to_string())
        .unwrap_or(raw)
}

fn html_attribute(node: &NodeRef, attribute: &str, absolute: bool) -> Option<String> {
    let element = node.as_element()?;
    let attributes = element.attributes.borrow();
    let raw = attributes.get(attribute)?.to_owned();
    if absolute && attribute == "src" && raw.starts_with("data:image/") {
        for lazy_attribute in ["data-lazy-src", "data-src", "data-url"] {
            if let Some(value) = attributes.get(lazy_attribute)
                && !value.trim().is_empty()
            {
                return Some(value.to_owned());
            }
        }
    }
    Some(raw)
}

fn html_inner(node: &NodeRef) -> String {
    node.children()
        .map(|child| child.to_string())
        .collect::<String>()
}

fn nearest_element_parent(node: &NodeRef) -> Option<NodeRef> {
    let mut parent = node.parent();
    while let Some(candidate) = parent {
        if candidate.as_element().is_some() {
            return Some(candidate);
        }
        parent = candidate.parent();
    }
    None
}

fn previous_element_sibling(node: &NodeRef) -> Option<NodeRef> {
    let mut sibling = node.previous_sibling();
    while let Some(candidate) = sibling {
        if candidate.as_element().is_some() {
            return Some(candidate);
        }
        sibling = candidate.previous_sibling();
    }
    None
}

fn canvas_dimension(value: f32) -> Option<u32> {
    if !value.is_finite() || value <= 0.0 || value > u32::MAX as f32 {
        return None;
    }
    Some(value.round().max(1.0) as u32)
}

#[allow(clippy::too_many_arguments)]
fn copy_bitmap_region(
    target: &mut RgbaImage,
    source: &RgbaImage,
    src_x: f32,
    src_y: f32,
    src_width: f32,
    src_height: f32,
    dst_x: f32,
    dst_y: f32,
    dst_width: f32,
    dst_height: f32,
) -> bool {
    if !src_x.is_finite()
        || !src_y.is_finite()
        || src_x < 0.0
        || src_y < 0.0
        || !dst_x.is_finite()
        || !dst_y.is_finite()
    {
        return false;
    }
    let Some(src_width) = canvas_dimension(src_width) else {
        return false;
    };
    let Some(src_height) = canvas_dimension(src_height) else {
        return false;
    };
    let Some(dst_width) = canvas_dimension(dst_width) else {
        return false;
    };
    let Some(dst_height) = canvas_dimension(dst_height) else {
        return false;
    };
    let src_x = src_x.floor() as u32;
    let src_y = src_y.floor() as u32;
    if src_x >= source.width() || src_y >= source.height() {
        return false;
    }
    let src_width = src_width.min(source.width() - src_x);
    let src_height = src_height.min(source.height() - src_y);
    let cropped = image::imageops::crop_imm(source, src_x, src_y, src_width, src_height).to_image();
    let rendered = if cropped.width() == dst_width && cropped.height() == dst_height {
        cropped
    } else {
        image::imageops::resize(&cropped, dst_width, dst_height, FilterType::Triangle)
    };
    image::imageops::overlay(
        target,
        &rendered,
        dst_x.floor() as i64,
        dst_y.floor() as i64,
    );
    true
}

fn html_nodes(item: &StoreItem) -> Option<Vec<HtmlNode>> {
    match item {
        StoreItem::Html(node) => Some(vec![node.clone()]),
        StoreItem::HtmlList(nodes) => Some(nodes.clone()),
        _ => None,
    }
}

fn select_nodes(node: &HtmlNode, selector: &str) -> Result<Vec<HtmlNode>> {
    let selected = node
        .node
        .select(selector)
        .map_err(|_| anyhow!("invalid CSS selector {selector:?}"))?;
    Ok(selected
        .map(|element| HtmlNode {
            node: element.as_node().clone(),
            base_url: node.base_url.clone(),
        })
        .collect())
}

fn method_from_code(value: i32) -> Option<Method> {
    Some(match value {
        0 => Method::GET,
        1 => Method::POST,
        2 => Method::PUT,
        3 => Method::HEAD,
        4 => Method::DELETE,
        5 => Method::PATCH,
        6 => Method::OPTIONS,
        7 => Method::CONNECT,
        8 => Method::TRACE,
        _ => return None,
    })
}

/// Detects a Cloudflare interstitial ("Just a moment…" / Turnstile) response.
///
/// The strongest signal is Cloudflare's own `cf-mitigated: challenge` header,
/// which it stamps on every managed-challenge response. As a fallback (some
/// deployments omit that header) we look for the challenge markup, but only when
/// the status and `server` header already point at Cloudflare, so a source that
/// legitimately returns a 403/503 JSON body is never misclassified.
fn is_cloudflare_challenge(
    status: u16,
    headers: &reqwest::header::HeaderMap,
    data: &[u8],
) -> bool {
    if headers
        .get("cf-mitigated")
        .and_then(|value| value.to_str().ok())
        .map(|value| value.eq_ignore_ascii_case("challenge"))
        .unwrap_or(false)
    {
        return true;
    }
    if !matches!(status, 403 | 429 | 503) {
        return false;
    }
    let served_by_cloudflare = headers
        .get(reqwest::header::SERVER)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.eq_ignore_ascii_case("cloudflare"))
        .unwrap_or(false);
    if !served_by_cloudflare {
        return false;
    }
    let head = &data[..data.len().min(8192)];
    let Ok(text) = std::str::from_utf8(head) else {
        return false;
    };
    text.contains("challenge-platform")
        || text.contains("Just a moment")
        || text.contains("_cf_chl_opt")
        || text.contains("cf-chl")
        || text.contains("cf_challenge")
}

fn send_request(state: &mut HostState, rid: i32) -> i32 {
    let Some(StoreItem::Request(request)) = state.descriptors.get_mut(&rid) else {
        return -1;
    };
    let Some(url) = request.url.clone() else {
        return -4;
    };
    if !request.headers.contains_key(reqwest::header::USER_AGENT) {
        request.headers.insert(
            reqwest::header::USER_AGENT,
            reqwest::header::HeaderValue::from_static(DEFAULT_USER_AGENT),
        );
    }
    let client = match reqwest::blocking::Client::builder().build() {
        Ok(client) => client,
        Err(_) => return -10,
    };
    let mut builder = client
        .request(request.method.clone(), url)
        .headers(request.headers.clone());
    if let Some(body) = request.body.clone() {
        builder = builder.body(body);
    }
    if let Some(timeout) = request.timeout
        && timeout.is_finite()
        && timeout > 0.0
    {
        builder = builder.timeout(std::time::Duration::from_secs_f64(timeout));
    }
    let Ok(response) = builder.send() else {
        return -10;
    };
    let final_url = response.url().to_string();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let Ok(data) = response.bytes() else {
        return -10;
    };
    let cloudflare_challenge = is_cloudflare_challenge(status, &headers, &data);
    request.response = Some(NetResponse {
        url: final_url,
        status,
        headers,
        data: data.to_vec(),
    });
    if cloudflare_challenge {
        state.cloudflare_challenge = true;
    }
    0
}

fn register_imports(linker: &mut Linker<HostState>) -> Result<()> {
    linker.func_wrap(
        "env",
        "print",
        |mut caller: Caller<'_, HostState>, ptr: i32, len: i32| match read_string(&caller, ptr, len)
        {
            Ok(value) => {
                caller.data_mut().stdout.push_str(&value);
                caller.data_mut().stdout.push('\n');
            }
            Err(error) => caller.data_mut().stdout.push_str(&format!("{error:#}\n")),
        },
    )?;
    linker.func_wrap("env", "abort", |mut caller: Caller<'_, HostState>| {
        caller.data_mut().stdout.push_str("Aidoku source aborted\n");
    })?;
    linker.func_wrap(
        "env",
        "send_partial_result",
        |mut caller: Caller<'_, HostState>, pointer: i32| {
            let bytes = read_bytes(&caller, pointer, 4)
                .ok()
                .and_then(|header| header.try_into().ok())
                .map(u32::from_le_bytes)
                .filter(|length| *length >= 8)
                .and_then(|length| read_bytes(&caller, pointer + 8, length as i32 - 8).ok());
            if let Some(bytes) = bytes {
                caller.data_mut().partial_results.push(bytes);
            }
        },
    )?;
    linker.func_wrap(
        "std",
        "print",
        |mut caller: Caller<'_, HostState>, ptr: i32, len: i32| {
            if let Ok(value) = read_string(&caller, ptr, len) {
                caller.data_mut().stdout.push_str(&value);
                caller.data_mut().stdout.push('\n');
            }
        },
    )?;
    linker.func_wrap("std", "abort", |mut caller: Caller<'_, HostState>| {
        caller.data_mut().stdout.push_str("Aidoku source aborted\n");
    })?;
    linker.func_wrap(
        "std",
        "destroy",
        |mut caller: Caller<'_, HostState>, rid: i32| {
            caller.data_mut().remove(rid);
        },
    )?;
    linker.func_wrap(
        "std",
        "buffer_len",
        |caller: Caller<'_, HostState>, rid: i32| -> i32 {
            caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(StoreItem::encoded)
                .map(|value| value.len() as i32)
                .unwrap_or(-1)
        },
    )?;
    linker.func_wrap(
        "std",
        "read_buffer",
        |mut caller: Caller<'_, HostState>, rid: i32, ptr: i32, size: i32| -> i32 {
            let Some(bytes) = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(StoreItem::encoded)
                .filter(|value| size >= 0 && size as usize <= value.len())
                .map(|value| value[..size as usize].to_vec())
            else {
                return -1;
            };
            write_bytes(&mut caller, ptr, &bytes)
                .map(|()| 0)
                .unwrap_or(-3)
        },
    )?;
    linker.func_wrap("std", "current_date", || -> f64 {
        chrono::Utc::now().timestamp() as f64
    })?;
    linker.func_wrap("std", "utc_offset", || -> i64 {
        chrono::Local::now().offset().utc_minus_local() as i64
    })?;
    linker.func_wrap(
        "std",
        "parse_date",
        |caller: Caller<'_, HostState>,
         date_ptr: i32,
         date_len: i32,
         format_ptr: i32,
         format_len: i32,
         _locale_ptr: i32,
         _locale_len: i32,
         timezone_ptr: i32,
         timezone_len: i32|
         -> f64 {
            let Ok(date) = read_string(&caller, date_ptr, date_len) else {
                return -4.0;
            };
            let Ok(format) = read_string(&caller, format_ptr, format_len) else {
                return -4.0;
            };
            let timezone = if timezone_len > 0 {
                read_string(&caller, timezone_ptr, timezone_len)
                    .ok()
                    .and_then(|value| value.parse::<chrono_tz::Tz>().ok())
                    .unwrap_or(chrono_tz::UTC)
            } else {
                chrono_tz::UTC
            };
            chrono::NaiveDateTime::parse_from_str(&date, &swift_date_format(&format))
                .ok()
                .and_then(|date| date.and_local_timezone(timezone).single())
                .map(|date| date.timestamp() as f64)
                .unwrap_or(-5.0)
        },
    )?;

    linker.func_wrap(
        "defaults",
        "get",
        |mut caller: Caller<'_, HostState>, key_ptr: i32, key_len: i32| -> i32 {
            let Ok(key) = read_string(&caller, key_ptr, key_len) else {
                return -1;
            };
            let Some(value) = caller.data().defaults.get(&key).cloned() else {
                return -2;
            };
            caller.data_mut().store(StoreItem::Encoded(value))
        },
    )?;
    linker.func_wrap(
        "defaults",
        "set",
        |mut caller: Caller<'_, HostState>,
         key_ptr: i32,
         key_len: i32,
         kind: i32,
         value_ptr: i32|
         -> i32 {
            if !(0..=6).contains(&kind) {
                return -2;
            }
            let Ok(key) = read_string(&caller, key_ptr, key_len) else {
                return -1;
            };
            let Ok(length_bytes) = read_bytes(&caller, value_ptr, 4) else {
                return -4;
            };
            let Ok(length_bytes) = <[u8; 4]>::try_from(length_bytes) else {
                return -4;
            };
            let length = u32::from_le_bytes(length_bytes) as i32;
            if length < 8 {
                return -4;
            }
            let Ok(value) = read_bytes(&caller, value_ptr + 8, length - 8) else {
                return -4;
            };
            if kind == 6 {
                caller.data_mut().defaults.remove(&key);
            } else {
                caller.data_mut().defaults.insert(key, value);
            }
            0
        },
    )?;

    linker.func_wrap(
        "net",
        "init",
        |mut caller: Caller<'_, HostState>, method: i32| -> i32 {
            let Some(method) = method_from_code(method) else {
                return -3;
            };
            caller
                .data_mut()
                .store(StoreItem::Request(Box::new(NetRequest {
                    method,
                    url: None,
                    headers: reqwest::header::HeaderMap::new(),
                    body: None,
                    timeout: None,
                    response: None,
                })))
        },
    )?;
    linker.func_wrap(
        "net",
        "set_url",
        |mut caller: Caller<'_, HostState>, rid: i32, ptr: i32, len: i32| -> i32 {
            let Ok(url) = read_string(&caller, ptr, len) else {
                return -2;
            };
            if reqwest::Url::parse(&url).is_err() {
                return -4;
            }
            let Some(StoreItem::Request(request)) = caller.data_mut().descriptors.get_mut(&rid)
            else {
                return -1;
            };
            request.url = Some(url);
            0
        },
    )?;
    linker.func_wrap(
        "net",
        "set_header",
        |mut caller: Caller<'_, HostState>,
         rid: i32,
         key_ptr: i32,
         key_len: i32,
         value_ptr: i32,
         value_len: i32|
         -> i32 {
            let Ok(key) = read_string(&caller, key_ptr, key_len) else {
                return -2;
            };
            let Ok(value) = read_string(&caller, value_ptr, value_len) else {
                return -2;
            };
            let Ok(key) = reqwest::header::HeaderName::from_bytes(key.as_bytes()) else {
                return -2;
            };
            let Ok(value) = reqwest::header::HeaderValue::from_str(&value) else {
                return -2;
            };
            let Some(StoreItem::Request(request)) = caller.data_mut().descriptors.get_mut(&rid)
            else {
                return -1;
            };
            request.headers.insert(key, value);
            0
        },
    )?;
    linker.func_wrap(
        "net",
        "set_body",
        |mut caller: Caller<'_, HostState>, rid: i32, ptr: i32, len: i32| -> i32 {
            let Ok(body) = read_bytes(&caller, ptr, len) else {
                return -2;
            };
            let Some(StoreItem::Request(request)) = caller.data_mut().descriptors.get_mut(&rid)
            else {
                return -1;
            };
            request.body = Some(body);
            0
        },
    )?;
    linker.func_wrap(
        "net",
        "send",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            send_request(caller.data_mut(), rid)
        },
    )?;
    linker.func_wrap(
        "net",
        "send_all",
        |mut caller: Caller<'_, HostState>, rid_ptr: i32, len: i32| -> i32 {
            if len < 0 {
                return -1;
            }
            let Ok(bytes) = read_bytes(&caller, rid_ptr, len.saturating_mul(4)) else {
                return -1;
            };
            let rids = bytes
                .chunks_exact(4)
                .map(|chunk| i32::from_le_bytes(chunk.try_into().expect("four-byte chunk")))
                .collect::<Vec<_>>();
            let results = rids
                .into_iter()
                .map(|rid| send_request(caller.data_mut(), rid))
                .collect::<Vec<_>>();
            let was_error = results.iter().any(|result| *result != 0);
            let encoded = results
                .into_iter()
                .flat_map(i32::to_le_bytes)
                .collect::<Vec<_>>();
            if write_bytes(&mut caller, rid_ptr, &encoded).is_err() {
                return -11;
            }
            if was_error { -10 } else { 0 }
        },
    )?;
    linker.func_wrap(
        "net",
        "set_rate_limit",
        |_permits: i32, _period: i32, _unit: i32| {},
    )?;
    linker.func_wrap(
        "net",
        "data_len",
        |caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let Some(StoreItem::Request(request)) = caller.data().descriptors.get(&rid) else {
                return -1;
            };
            request
                .response
                .as_ref()
                .map(|response| response.data.len() as i32)
                .unwrap_or(-8)
        },
    )?;
    linker.func_wrap(
        "net",
        "read_data",
        |mut caller: Caller<'_, HostState>, rid: i32, ptr: i32, size: i32| -> i32 {
            let Some(data) = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(|item| match item {
                    StoreItem::Request(request) => request.response.as_ref(),
                    _ => None,
                })
                .filter(|response| size >= 0 && size as usize <= response.data.len())
                .map(|response| response.data[..size as usize].to_vec())
            else {
                return -8;
            };
            write_bytes(&mut caller, ptr, &data)
                .map(|()| 0)
                .unwrap_or(-11)
        },
    )?;
    linker.func_wrap(
        "net",
        "html",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let Some((text, url)) = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(|item| match item {
                    StoreItem::Request(request) => request.response.as_ref(),
                    _ => None,
                })
                .and_then(|response| {
                    std::str::from_utf8(&response.data)
                        .ok()
                        .map(|text| (text.to_owned(), response.url.clone()))
                })
            else {
                return -8;
            };
            let document = parse_html(&text, Some(url));
            caller.data_mut().store(StoreItem::Html(document))
        },
    )?;
    linker.func_wrap(
        "net",
        "get_status_code",
        |caller: Caller<'_, HostState>, rid: i32| -> i32 {
            caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(|item| match item {
                    StoreItem::Request(request) => request.response.as_ref(),
                    _ => None,
                })
                .map(|response| response.status as i32)
                .unwrap_or(-8)
        },
    )?;
    linker.func_wrap(
        "net",
        "get_header",
        |mut caller: Caller<'_, HostState>, rid: i32, key_ptr: i32, key_len: i32| -> i32 {
            let Ok(key) = read_string(&caller, key_ptr, key_len) else {
                return -2;
            };
            let Ok(name) = reqwest::header::HeaderName::from_bytes(key.as_bytes()) else {
                return -2;
            };
            let value = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(|item| match item {
                    StoreItem::Request(request) => request.response.as_ref(),
                    _ => None,
                })
                .map(|response| {
                    response
                        .headers
                        .get_all(name)
                        .iter()
                        .filter_map(|value| value.to_str().ok())
                        .collect::<Vec<_>>()
                        .join(", ")
                });
            match value.filter(|value| !value.is_empty()) {
                Some(value) => caller.data_mut().store(StoreItem::String(value)),
                None => -7,
            }
        },
    )?;

    linker.func_wrap(
        "html",
        "parse_fragment",
        |mut caller: Caller<'_, HostState>,
         ptr: i32,
         len: i32,
         base_ptr: i32,
         base_len: i32|
         -> i32 {
            let Ok(text) = read_string(&caller, ptr, len) else {
                return -2;
            };
            let Ok(base_url) = read_string(&caller, base_ptr, base_len) else {
                return -2;
            };
            caller
                .data_mut()
                .store(StoreItem::Html(parse_html(&text, Some(base_url))))
        },
    )?;
    linker.func_wrap(
        "html",
        "parse",
        |mut caller: Caller<'_, HostState>,
         ptr: i32,
         len: i32,
         base_ptr: i32,
         base_len: i32|
         -> i32 {
            let Ok(text) = read_string(&caller, ptr, len) else {
                return -2;
            };
            let Ok(base_url) = read_string(&caller, base_ptr, base_len) else {
                return -2;
            };
            caller
                .data_mut()
                .store(StoreItem::Html(parse_html(&text, Some(base_url))))
        },
    )?;
    linker.func_wrap(
        "html",
        "select",
        |mut caller: Caller<'_, HostState>, rid: i32, ptr: i32, len: i32| -> i32 {
            let Ok(selector) = read_string(&caller, ptr, len) else {
                return -2;
            };
            let Some(nodes) = caller.data().descriptors.get(&rid).and_then(html_nodes) else {
                return -1;
            };
            let selected = nodes
                .iter()
                .filter_map(|node| select_nodes(node, &selector).ok())
                .flatten()
                .collect::<Vec<_>>();
            caller.data_mut().store(StoreItem::HtmlList(selected))
        },
    )?;
    linker.func_wrap(
        "html",
        "select_first",
        |mut caller: Caller<'_, HostState>, rid: i32, ptr: i32, len: i32| -> i32 {
            let Ok(selector) = read_string(&caller, ptr, len) else {
                return -2;
            };
            let Some(nodes) = caller.data().descriptors.get(&rid).and_then(html_nodes) else {
                return -1;
            };
            let first = nodes
                .iter()
                .filter_map(|node| select_nodes(node, &selector).ok())
                .flatten()
                .next();
            match first {
                Some(node) => caller.data_mut().store(StoreItem::Html(node)),
                None => -1,
            }
        },
    )?;
    linker.func_wrap(
        "html",
        "size",
        |caller: Caller<'_, HostState>, rid: i32| -> i32 {
            match caller.data().descriptors.get(&rid) {
                Some(StoreItem::HtmlList(nodes)) => nodes.len() as i32,
                Some(StoreItem::Html(_)) => 1,
                _ => -1,
            }
        },
    )?;
    linker.func_wrap(
        "html",
        "get",
        |mut caller: Caller<'_, HostState>, rid: i32, index: i32| -> i32 {
            let Some(node) = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(|item| match item {
                    StoreItem::HtmlList(nodes) if index >= 0 => nodes.get(index as usize),
                    _ => None,
                })
                .cloned()
            else {
                return -1;
            };
            caller.data_mut().store(StoreItem::Html(node))
        },
    )?;
    linker.func_wrap(
        "html",
        "last",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let Some(node) = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(|item| match item {
                    StoreItem::HtmlList(nodes) => nodes.last(),
                    _ => None,
                })
                .cloned()
            else {
                return -1;
            };
            caller.data_mut().store(StoreItem::Html(node))
        },
    )?;
    linker.func_wrap(
        "html",
        "text",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let Some(nodes) = caller.data().descriptors.get(&rid).and_then(html_nodes) else {
                return -1;
            };
            let value = nodes
                .iter()
                .map(|node| node.node.text_contents())
                .collect::<Vec<_>>()
                .join(" ");
            caller.data_mut().store(StoreItem::String(value))
        },
    )?;
    linker.func_wrap(
        "html",
        "own_text",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let Some(nodes) = caller.data().descriptors.get(&rid).and_then(html_nodes) else {
                return -1;
            };
            let value = nodes
                .iter()
                .flat_map(|node| node.node.children())
                .filter_map(|child| child.as_text().map(|text| text.borrow().to_string()))
                .collect::<Vec<_>>()
                .join(" ");
            caller.data_mut().store(StoreItem::String(value))
        },
    )?;
    linker.func_wrap(
        "html",
        "data",
        |_caller: Caller<'_, HostState>, _rid: i32| -> i32 { -1 },
    )?;
    linker.func_wrap(
        "html",
        "html",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let Some(nodes) = caller.data().descriptors.get(&rid).and_then(html_nodes) else {
                return -1;
            };
            let value = nodes
                .iter()
                .map(|node| html_inner(&node.node))
                .collect::<Vec<_>>()
                .join("");
            caller.data_mut().store(StoreItem::String(value))
        },
    )?;
    linker.func_wrap(
        "html",
        "base_uri",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let value = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .and_then(|node| node.base_url);
            match value {
                Some(value) => caller.data_mut().store(StoreItem::String(value)),
                None => -5,
            }
        },
    )?;
    linker.func_wrap(
        "html",
        "set_text",
        |_caller: Caller<'_, HostState>, _rid: i32, _ptr: i32, _len: i32| -> i32 { -1 },
    )?;
    linker.func_wrap(
        "html",
        "remove",
        |_caller: Caller<'_, HostState>, _rid: i32| -> i32 { -1 },
    )?;
    linker.func_wrap(
        "html",
        "children",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let Some(parent) = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
            else {
                return -1;
            };
            let children = parent
                .node
                .children()
                .filter(|node| node.as_element().is_some())
                .map(|node| HtmlNode {
                    node,
                    base_url: parent.base_url.clone(),
                })
                .collect::<Vec<_>>();
            caller.data_mut().store(StoreItem::HtmlList(children))
        },
    )?;
    linker.func_wrap(
        "html",
        "child_nodes",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let Some(parent) = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
            else {
                return -1;
            };
            let children = parent
                .node
                .children()
                .map(|node| HtmlNode {
                    node,
                    base_url: parent.base_url.clone(),
                })
                .collect::<Vec<_>>();
            caller.data_mut().store(StoreItem::HtmlList(children))
        },
    )?;
    linker.func_wrap(
        "html",
        "parent",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let parent = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .and_then(|node| {
                    nearest_element_parent(&node.node).map(|parent| HtmlNode {
                        node: parent,
                        base_url: node.base_url,
                    })
                });
            match parent {
                Some(parent) => caller.data_mut().store(StoreItem::Html(parent)),
                None => -5,
            }
        },
    )?;
    linker.func_wrap(
        "html",
        "previous",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let previous = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .and_then(|node| {
                    previous_element_sibling(&node.node).map(|previous| HtmlNode {
                        node: previous,
                        base_url: node.base_url,
                    })
                });
            match previous {
                Some(previous) => caller.data_mut().store(StoreItem::Html(previous)),
                None => -5,
            }
        },
    )?;
    linker.func_wrap(
        "html",
        "tag_name",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let value = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .and_then(|node| {
                    node.node
                        .as_element()
                        .map(|element| element.name.local.to_string())
                });
            match value {
                Some(value) => caller.data_mut().store(StoreItem::String(value)),
                None => -5,
            }
        },
    )?;
    linker.func_wrap(
        "html",
        "has_attr",
        |caller: Caller<'_, HostState>, rid: i32, ptr: i32, len: i32| -> i32 {
            let Ok(attribute) = read_string(&caller, ptr, len) else {
                return -2;
            };
            caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .and_then(|node| {
                    node.node.as_element().map(|element| {
                        i32::from(element.attributes.borrow().contains(attribute.as_str()))
                    })
                })
                .unwrap_or(-1)
        },
    )?;
    linker.func_wrap(
        "html",
        "kind",
        |caller: Caller<'_, HostState>, rid: i32| -> i32 {
            caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .map(|node| match node.node.data() {
                    NodeData::Text(_) => 2,
                    NodeData::Comment(_) => 4,
                    NodeData::Element(_) => 5,
                    NodeData::Document(_) | NodeData::DocumentFragment => 7,
                    _ => 1,
                })
                .unwrap_or(-1)
        },
    )?;
    linker.func_wrap(
        "html",
        "unescape",
        |mut caller: Caller<'_, HostState>, ptr: i32, len: i32| -> i32 {
            let Ok(value) = read_string(&caller, ptr, len) else {
                return -2;
            };
            let value = value
                .replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">");
            caller.data_mut().store(StoreItem::String(value))
        },
    )?;
    linker.func_wrap(
        "html",
        "class_name",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let value = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .and_then(|node| {
                    node.node.as_element().and_then(|element| {
                        element.attributes.borrow().get("class").map(str::to_owned)
                    })
                });
            match value {
                Some(value) => caller.data_mut().store(StoreItem::String(value)),
                None => -1,
            }
        },
    )?;
    linker.func_wrap(
        "html",
        "has_class",
        |caller: Caller<'_, HostState>, rid: i32, ptr: i32, len: i32| -> i32 {
            let Ok(class) = read_string(&caller, ptr, len) else {
                return -2;
            };
            caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .and_then(|node| {
                    node.node.as_element().map(|element| {
                        element
                            .attributes
                            .borrow()
                            .get("class")
                            .map(|classes| {
                                classes.split_ascii_whitespace().any(|item| item == class)
                            })
                            .unwrap_or(false)
                    })
                })
                .map(i32::from)
                .unwrap_or(-1)
        },
    )?;
    linker.func_wrap(
        "html",
        "first",
        |mut caller: Caller<'_, HostState>, rid: i32| -> i32 {
            let node = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(|item| match item {
                    StoreItem::HtmlList(nodes) => nodes.first(),
                    _ => None,
                })
                .cloned();
            match node {
                Some(node) => caller.data_mut().store(StoreItem::Html(node)),
                None => -1,
            }
        },
    )?;
    linker.func_wrap(
        "html",
        "attr",
        |mut caller: Caller<'_, HostState>, rid: i32, ptr: i32, len: i32| -> i32 {
            let Ok(key) = read_string(&caller, ptr, len) else {
                return -2;
            };
            let value = caller
                .data()
                .descriptors
                .get(&rid)
                .and_then(html_nodes)
                .and_then(|nodes| nodes.into_iter().next())
                .and_then(|node| {
                    let (attribute, absolute) = key
                        .strip_prefix("abs:")
                        .map(|attribute| (attribute, true))
                        .unwrap_or((key.as_str(), false));
                    let raw = html_attribute(&node.node, attribute, absolute)?;
                    if !absolute {
                        return Some(raw);
                    }
                    Some(absolute_attribute(raw, node.base_url.as_deref()))
                });
            match value {
                Some(value) => caller.data_mut().store(StoreItem::String(value)),
                None => -1,
            }
        },
    )?;

    linker.func_wrap(
        "js",
        "context_create",
        |mut caller: Caller<'_, HostState>| -> i32 {
            caller
                .data_mut()
                .store(StoreItem::JsContext(Box::default()))
        },
    )?;
    linker.func_wrap(
        "js",
        "context_eval",
        |mut caller: Caller<'_, HostState>, rid: i32, ptr: i32, len: i32| -> i32 {
            let Ok(source) = read_string(&caller, ptr, len) else {
                return -3;
            };
            let Some(StoreItem::JsContext(context)) = caller.data_mut().descriptors.get_mut(&rid)
            else {
                return -2;
            };
            let Ok(value) = context.eval(Source::from_bytes(&source)) else {
                return -1;
            };
            let Ok(value) = value.to_string(context) else {
                return -1;
            };
            let Ok(value) = value.to_std_string() else {
                return -1;
            };
            caller.data_mut().store(StoreItem::String(value))
        },
    )?;
    linker.func_wrap("js", "webview_create", || -> i32 { -1 })?;
    linker.func_wrap(
        "js",
        "webview_load_html",
        |_rid: i32, _html_ptr: i32, _html_len: i32, _url_ptr: i32, _url_len: i32| -> i32 { -1 },
    )?;
    linker.func_wrap("js", "webview_wait_for_load", |_rid: i32| -> i32 { -1 })?;
    linker.func_wrap(
        "js",
        "webview_eval",
        |_rid: i32, _ptr: i32, _len: i32| -> i32 { -1 },
    )?;
    linker.func_wrap(
        "canvas",
        "new_image",
        |mut caller: Caller<'_, HostState>, ptr: i32, len: i32| -> i32 {
            let Ok(data) = read_bytes(&caller, ptr, len) else {
                return -11;
            };
            let Ok(decoded) = image::load_from_memory(&data) else {
                return -3;
            };
            let image = decoded.to_rgba8();
            if u64::from(image.width()) * u64::from(image.height()) > MAX_CANVAS_PIXELS {
                return -3;
            }
            caller
                .data_mut()
                .store(StoreItem::Image(CanvasBitmap { image }))
        },
    )?;
    linker.func_wrap(
        "canvas",
        "new_context",
        |mut caller: Caller<'_, HostState>, width: f32, height: f32| -> i32 {
            let Some(width) = canvas_dimension(width) else {
                return -1;
            };
            let Some(height) = canvas_dimension(height) else {
                return -1;
            };
            if u64::from(width) * u64::from(height) > MAX_CANVAS_PIXELS {
                return -1;
            }
            caller.data_mut().store(StoreItem::Canvas(CanvasBitmap {
                image: RgbaImage::new(width, height),
            }))
        },
    )?;
    linker.func_wrap(
        "canvas",
        "copy_image",
        |mut caller: Caller<'_, HostState>,
         context: i32,
         image: i32,
         src_x: f32,
         src_y: f32,
         src_width: f32,
         src_height: f32,
         dst_x: f32,
         dst_y: f32,
         dst_width: f32,
         dst_height: f32|
         -> i32 {
            let source = caller
                .data()
                .descriptors
                .get(&image)
                .and_then(|item| match item {
                    StoreItem::Image(bitmap) | StoreItem::Canvas(bitmap) => {
                        Some(bitmap.image.clone())
                    }
                    _ => None,
                });
            let Some(source) = source else {
                return -3;
            };
            let Some(StoreItem::Canvas(target)) = caller.data_mut().descriptors.get_mut(&context)
            else {
                return -1;
            };
            if copy_bitmap_region(
                &mut target.image,
                &source,
                src_x,
                src_y,
                src_width,
                src_height,
                dst_x,
                dst_y,
                dst_width,
                dst_height,
            ) {
                0
            } else {
                -3
            }
        },
    )?;
    linker.func_wrap(
        "canvas",
        "draw_image",
        |mut caller: Caller<'_, HostState>,
         context: i32,
         image: i32,
         dst_x: f32,
         dst_y: f32,
         dst_width: f32,
         dst_height: f32|
         -> i32 {
            let source = caller
                .data()
                .descriptors
                .get(&image)
                .and_then(|item| match item {
                    StoreItem::Image(bitmap) | StoreItem::Canvas(bitmap) => {
                        Some(bitmap.image.clone())
                    }
                    _ => None,
                });
            let Some(source) = source else {
                return -3;
            };
            let Some(StoreItem::Canvas(target)) = caller.data_mut().descriptors.get_mut(&context)
            else {
                return -1;
            };
            if copy_bitmap_region(
                &mut target.image,
                &source,
                0.0,
                0.0,
                source.width() as f32,
                source.height() as f32,
                dst_x,
                dst_y,
                dst_width,
                dst_height,
            ) {
                0
            } else {
                -3
            }
        },
    )?;
    linker.func_wrap(
        "canvas",
        "get_image",
        |mut caller: Caller<'_, HostState>, context: i32| -> i32 {
            let image = caller
                .data()
                .descriptors
                .get(&context)
                .and_then(|item| match item {
                    StoreItem::Canvas(bitmap) => Some(bitmap.clone()),
                    _ => None,
                });
            match image {
                Some(image) => caller.data_mut().store(StoreItem::Image(image)),
                None => -1,
            }
        },
    )?;
    linker.func_wrap(
        "canvas",
        "get_image_width",
        |caller: Caller<'_, HostState>, image: i32| -> f32 {
            caller
                .data()
                .descriptors
                .get(&image)
                .and_then(|item| match item {
                    StoreItem::Image(bitmap) | StoreItem::Canvas(bitmap) => {
                        Some(bitmap.image.width() as f32)
                    }
                    _ => None,
                })
                .unwrap_or(-2.0)
        },
    )?;
    linker.func_wrap(
        "canvas",
        "get_image_height",
        |caller: Caller<'_, HostState>, image: i32| -> f32 {
            caller
                .data()
                .descriptors
                .get(&image)
                .and_then(|item| match item {
                    StoreItem::Image(bitmap) | StoreItem::Canvas(bitmap) => {
                        Some(bitmap.image.height() as f32)
                    }
                    _ => None,
                })
                .unwrap_or(-2.0)
        },
    )?;
    linker.func_wrap(
        "canvas",
        "get_image_data",
        |mut caller: Caller<'_, HostState>, image: i32| -> i32 {
            let bitmap = caller
                .data()
                .descriptors
                .get(&image)
                .and_then(|item| match item {
                    StoreItem::Image(bitmap) | StoreItem::Canvas(bitmap) => {
                        Some(bitmap.image.clone())
                    }
                    _ => None,
                });
            let Some(bitmap) = bitmap else {
                return -2;
            };
            let mut output = Cursor::new(Vec::new());
            if DynamicImage::ImageRgba8(bitmap)
                .write_to(&mut output, image::ImageFormat::Png)
                .is_err()
            {
                return -3;
            }
            caller
                .data_mut()
                .store(StoreItem::Encoded(output.into_inner()))
        },
    )?;
    Ok(())
}

fn swift_date_format(format: &str) -> String {
    let mut output = String::new();
    let mut chars = format.chars().peekable();
    while let Some(character) = chars.next() {
        let token = match character {
            'y' => {
                let mut count = 1;
                while chars.peek() == Some(&'y') {
                    chars.next();
                    count += 1;
                }
                if count == 2 { "%y" } else { "%Y" }
            }
            'M' => {
                let mut count = 1;
                while chars.peek() == Some(&'M') {
                    chars.next();
                    count += 1;
                }
                match count {
                    1 | 2 => "%m",
                    3 => "%b",
                    _ => "%B",
                }
            }
            'd' => {
                while chars.peek() == Some(&'d') {
                    chars.next();
                }
                "%d"
            }
            'H' => {
                while chars.peek() == Some(&'H') {
                    chars.next();
                }
                "%H"
            }
            'h' => {
                while chars.peek() == Some(&'h') {
                    chars.next();
                }
                "%I"
            }
            'm' => {
                while chars.peek() == Some(&'m') {
                    chars.next();
                }
                "%M"
            }
            's' => {
                while chars.peek() == Some(&'s') {
                    chars.next();
                }
                "%S"
            }
            'a' => "%p",
            other => {
                output.push(other);
                continue;
            }
        };
        output.push_str(token);
    }
    output
}

struct EmbeddedRuntime {
    store: Store<HostState>,
    instance: Instance,
    module: Module,
    memory: Memory,
}

impl EmbeddedRuntime {
    fn load(wasm: &[u8], defaults: HashMap<String, Vec<u8>>) -> Result<Self> {
        let engine = Engine::default();
        let module = Module::new(&engine, wasm).context("failed to parse Aidoku WebAssembly")?;
        let mut linker = Linker::new(&engine);
        register_imports(&mut linker)?;
        let mut store = Store::new(&engine, HostState::new(defaults));
        let instance = linker
            .instantiate_and_start(&mut store, &module)
            .context("failed to instantiate Aidoku WebAssembly")?;
        let memory = instance
            .get_memory(&store, "memory")
            .ok_or_else(|| anyhow!("Aidoku source does not export memory"))?;
        store.data_mut().memory = Some(memory);
        if let Ok(start) = instance.get_typed_func::<(), ()>(&store, "start") {
            start
                .call(&mut store, ())
                .context("Aidoku source start function failed")?;
        }
        Ok(Self {
            store,
            instance,
            module,
            memory,
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

    fn take_result<T: DeserializeOwned>(&mut self, pointer: i32) -> Result<T> {
        if pointer <= 0 {
            if self.store.data().cloudflare_challenge {
                bail!("Cloudflare challenge blocked this source");
            }
            let log = self.store.data().stdout.trim();
            if log.is_empty() {
                bail!("Aidoku source returned error code {pointer}");
            }
            bail!("Aidoku source returned error code {pointer}: {log}");
        }
        let header = read_u32(&self.store, self.memory, pointer)? as i32;
        let result = if header == -1 {
            let length = read_u32(&self.store, self.memory, pointer + 8)? as usize;
            let mut bytes = vec![0_u8; length.saturating_sub(12)];
            self.memory
                .read(&self.store, pointer as usize + 12, &mut bytes)
                .context("failed to read Aidoku source error")?;
            Err(anyhow!(
                "Aidoku source error: {}",
                String::from_utf8_lossy(&bytes)
            ))
        } else {
            let length = header as usize;
            if length < 8 {
                Err(anyhow!("Aidoku source returned a malformed result"))
            } else {
                let mut bytes = vec![0_u8; length - 8];
                self.memory
                    .read(&self.store, pointer as usize + 8, &mut bytes)
                    .context("failed to read Aidoku result")?;
                postcard::from_bytes(&bytes).context("failed to decode Aidoku result")
            }
        };
        let free = self
            .instance
            .get_typed_func::<i32, ()>(&self.store, "free_result")
            .context("Aidoku source does not export free_result")?;
        free.call(&mut self.store, pointer)
            .context("Aidoku source failed to free its result")?;
        if result.is_err() && self.store.data().cloudflare_challenge {
            bail!("Cloudflare challenge blocked this source");
        }
        result
    }

    fn search(&mut self, query: Option<&str>, page: i32) -> Result<SearchPageResult> {
        if page < 1 {
            bail!("search page must be at least 1");
        }
        let query_descriptor = query
            .filter(|value| !value.is_empty())
            .map(|value| {
                self.store
                    .data_mut()
                    .store(StoreItem::String(value.to_owned()))
            })
            .unwrap_or(-1);
        let filters_descriptor = self
            .store
            .data_mut()
            .store_encoded(&Vec::<FilterValue>::new())?;
        let function = self
            .instance
            .get_typed_func::<(i32, i32, i32), i32>(&self.store, "get_search_manga_list")
            .context("Aidoku source does not export get_search_manga_list")?;
        let pointer = function
            .call(
                &mut self.store,
                (query_descriptor, page, filters_descriptor),
            )
            .context("Aidoku search function trapped")?;
        if query_descriptor > 0 {
            self.store.data_mut().remove(query_descriptor);
        }
        self.store.data_mut().remove(filters_descriptor);
        let mut result: SearchPageResult = self.take_result(pointer)?;
        for bytes in self.store.data_mut().partial_results.drain(..) {
            let partial = match postcard::from_bytes::<Manga>(&bytes) {
                Ok(partial) => partial,
                Err(_) => continue,
            };
            if !result.entries.iter().any(|manga| manga.key == partial.key) {
                result.entries.push(partial);
            }
        }
        Ok(result)
    }

    fn list(&mut self, listing: &Listing, page: i32) -> Result<SearchPageResult> {
        if page < 1 {
            bail!("listing page must be at least 1");
        }
        let descriptor = self.store.data_mut().store_encoded(listing)?;
        let function = self
            .instance
            .get_typed_func::<(i32, i32), i32>(&self.store, "get_manga_list")
            .context("Aidoku source does not export get_manga_list")?;
        let pointer = function
            .call(&mut self.store, (descriptor, page))
            .context("Aidoku listing function trapped")?;
        self.store.data_mut().remove(descriptor);
        self.take_result(pointer)
    }

    fn details(&mut self, manga: &Manga) -> Result<Manga> {
        let descriptor = self.store.data_mut().store_encoded(manga)?;
        let function = self
            .instance
            .get_typed_func::<(i32, i32, i32), i32>(&self.store, "get_manga_update")
            .context("Aidoku source does not export get_manga_update")?;
        let pointer = function
            .call(&mut self.store, (descriptor, 1, 1))
            .context("Aidoku manga update function trapped")?;
        self.store.data_mut().remove(descriptor);
        let mut result: Manga = self.take_result(pointer)?;
        for bytes in self.store.data_mut().partial_results.drain(..) {
            let partial = match postcard::from_bytes::<Manga>(&bytes) {
                Ok(partial) => partial,
                Err(_) => continue,
            };
            if partial
                .chapters
                .as_ref()
                .is_some_and(|value| !value.is_empty())
            {
                result.chapters = partial.chapters;
            }
        }
        Ok(result)
    }

    fn pages(&mut self, manga: &Manga, chapter: &Chapter) -> Result<Vec<HostPage>> {
        let manga_descriptor = self.store.data_mut().store_encoded(manga)?;
        let chapter_descriptor = self.store.data_mut().store_encoded(chapter)?;
        let function = self
            .instance
            .get_typed_func::<(i32, i32), i32>(&self.store, "get_page_list")
            .context("Aidoku source does not export get_page_list")?;
        let pointer = function
            .call(&mut self.store, (manga_descriptor, chapter_descriptor))
            .context("Aidoku page list function trapped")?;
        self.store.data_mut().remove(manga_descriptor);
        self.store.data_mut().remove(chapter_descriptor);
        self.take_result(pointer)
    }

    fn image_request(
        &mut self,
        url: &str,
        context: Option<&HashMap<String, String>>,
    ) -> Result<Option<ResolvedImageRequest>> {
        let Ok(function) = self
            .instance
            .get_typed_func::<(i32, i32), i32>(&self.store, "get_image_request")
        else {
            return Ok(None);
        };
        let url_descriptor = self
            .store
            .data_mut()
            .store(StoreItem::String(url.to_owned()));
        let context_descriptor = context
            .map(|context| self.store.data_mut().store_encoded(context))
            .transpose()?
            .unwrap_or(-1);
        let pointer = function
            .call(&mut self.store, (url_descriptor, context_descriptor))
            .context("Aidoku image request function trapped")?;
        self.store.data_mut().remove(url_descriptor);
        if context_descriptor > 0 {
            self.store.data_mut().remove(context_descriptor);
        }
        let request_descriptor: i32 = self.take_result(pointer)?;
        let resolved = self
            .store
            .data()
            .descriptors
            .get(&request_descriptor)
            .and_then(|item| match item {
                StoreItem::Request(request) => Some(ResolvedImageRequest {
                    url: request.url.clone().unwrap_or_else(|| url.to_owned()),
                    headers: request
                        .headers
                        .iter()
                        .filter_map(|(key, value)| {
                            value
                                .to_str()
                                .ok()
                                .map(|value| (key.as_str().to_owned(), value.to_owned()))
                        })
                        .collect(),
                }),
                _ => None,
            })
            .ok_or_else(|| anyhow!("Aidoku image request returned an invalid descriptor"))?;
        self.store.data_mut().remove(request_descriptor);
        Ok(Some(resolved))
    }
}

fn execute(request: &Value) -> Result<Value> {
    let command = request
        .get("command")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing Aidoku command"))?;
    let package_path = request
        .get("packagePath")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing Aidoku packagePath"))?;
    let package = AixPackage::open(package_path)?;
    let mut runtime = EmbeddedRuntime::load(&package.wasm, package.defaults.clone())?;
    let source = package.manifest["info"].clone();
    match command {
        "inspect" => Ok(json!({
            "protocolVersion": 1,
            "packagePath": package.path,
            "manifest": package.manifest,
            "runtime": runtime.capabilities(),
        })),
        "search" => {
            let query = request.get("query").and_then(Value::as_str);
            let page = request.get("page").and_then(Value::as_i64).unwrap_or(1) as i32;
            Ok(json!({
                "protocolVersion": 1,
                "source": source,
                "result": runtime.search(query, page)?,
            }))
        }
        "list" => {
            let listing: Listing = serde_json::from_value(
                request
                    .get("listing")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing Aidoku listing"))?,
            )
            .context("invalid Aidoku listing")?;
            let page = request.get("page").and_then(Value::as_i64).unwrap_or(1) as i32;
            Ok(json!({
                "protocolVersion": 1,
                "source": source,
                "result": runtime.list(&listing, page)?,
            }))
        }
        "details" => {
            let manga: Manga = serde_json::from_value(
                request
                    .get("manga")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing Aidoku manga"))?,
            )
            .context("invalid Aidoku manga")?;
            Ok(json!({
                "protocolVersion": 1,
                "source": source,
                "result": runtime.details(&manga)?,
            }))
        }
        "pages" => {
            let manga: Manga = serde_json::from_value(
                request
                    .get("manga")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing Aidoku manga"))?,
            )
            .context("invalid Aidoku manga")?;
            let chapter: Chapter = serde_json::from_value(
                request
                    .get("chapter")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing Aidoku chapter"))?,
            )
            .context("invalid Aidoku chapter")?;
            let pages = runtime.pages(&manga, &chapter)?;
            let pages = pages
                .into_iter()
                .map(|page| {
                    let resolved = match &page.content {
                        HostPageContent::Url(url, context) => {
                            runtime.image_request(url, context.as_ref()).ok().flatten()
                        }
                        _ => None,
                    };
                    ResolvedHostPage {
                        request_url: resolved.as_ref().map(|request| request.url.clone()),
                        request_headers: resolved
                            .map(|request| request.headers)
                            .unwrap_or_default(),
                        page,
                    }
                })
                .collect::<Vec<_>>();
            Ok(json!({
                "protocolVersion": 1,
                "source": source,
                "result": pages,
            }))
        }
        _ => bail!("unknown Aidoku command {command:?}"),
    }
}

pub fn invoke_json(input: &str) -> String {
    let response = serde_json::from_str::<Value>(input)
        .context("invalid Aidoku request JSON")
        .and_then(|request| execute(&request));
    match response {
        Ok(value) => serde_json::to_string(&value)
            .unwrap_or_else(|error| json!({"error": error.to_string()}).to_string()),
        Err(error) => {
            let message = format!("{error:#}");
            let code = if message.contains("Cloudflare challenge")
                || message.contains("CF challenge")
            {
                "CLOUDFLARE_CHALLENGE"
            } else if message.contains("unknown import")
                || message.contains("imported function type mismatch")
                || message.contains("failed to instantiate Aidoku WebAssembly")
            {
                "UNSUPPORTED_IMPORT"
            } else if message.contains("Aidoku package")
                || message.contains("Payload/")
                || message.contains("source manifest")
            {
                "INVALID_PACKAGE"
            } else {
                "RUNTIME_FAILED"
            };
            json!({"code": code, "error": message}).to_string()
        }
    }
}

#[unsafe(no_mangle)]
/// Executes one JSON request and returns an owned UTF-8 JSON response.
///
/// # Safety
///
/// `input` must be null or point to a valid NUL-terminated string for the
/// duration of this call. The returned pointer must be released exactly once
/// with [`fushi_aidoku_string_free`].
pub unsafe extern "C" fn fushi_aidoku_invoke(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return CString::new(r#"{"error":"Aidoku request pointer was null"}"#)
            .expect("static string has no null bytes")
            .into_raw();
    }
    let input = unsafe { CStr::from_ptr(input) }.to_string_lossy();
    CString::new(invoke_json(&input))
        .unwrap_or_else(|_| {
            CString::new(r#"{"error":"Aidoku response contained a null byte"}"#)
                .expect("static string has no null bytes")
        })
        .into_raw()
}

#[unsafe(no_mangle)]
/// Releases a response allocated by [`fushi_aidoku_invoke`].
///
/// # Safety
///
/// `pointer` must be null or a pointer returned by
/// [`fushi_aidoku_invoke`] that has not already been released.
pub unsafe extern "C" fn fushi_aidoku_string_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(unsafe { CString::from_raw(pointer) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_json_without_panicking_across_ffi() {
        let response: Value = serde_json::from_str(&invoke_json("not json")).unwrap();
        assert!(
            response["error"]
                .as_str()
                .unwrap()
                .contains("invalid Aidoku request JSON")
        );
    }

    #[test]
    fn detects_cloudflare_challenge_by_mitigated_header() {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert("cf-mitigated", "challenge".parse().unwrap());
        assert!(is_cloudflare_challenge(403, &headers, b""));
        // The header is authoritative regardless of status code.
        assert!(is_cloudflare_challenge(200, &headers, b""));
    }

    #[test]
    fn detects_cloudflare_challenge_by_interstitial_markup() {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(reqwest::header::SERVER, "cloudflare".parse().unwrap());
        let body = b"<!DOCTYPE html><html><head><title>Just a moment...</title>\
            <script src=\"/cdn-cgi/challenge-platform/h/b/orchestrate\"></script>";
        assert!(is_cloudflare_challenge(403, &headers, body));
        assert!(is_cloudflare_challenge(503, &headers, body));
    }

    #[test]
    fn does_not_flag_a_legitimate_403_json_body() {
        // A source that returns a real 403 JSON error (not served by Cloudflare,
        // no challenge markup) must never be misread as a challenge.
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(reqwest::header::SERVER, "nginx".parse().unwrap());
        assert!(!is_cloudflare_challenge(403, &headers, br#"{"error":"forbidden"}"#));
        // Cloudflare-served but a normal 200 JSON payload is fine too.
        let mut cf_headers = reqwest::header::HeaderMap::new();
        cf_headers.insert(reqwest::header::SERVER, "cloudflare".parse().unwrap());
        assert!(!is_cloudflare_challenge(200, &cf_headers, br#"{"data":[]}"#));
    }

    #[test]
    fn converts_the_date_tokens_used_by_html_sources() {
        assert_eq!(
            swift_date_format("yyyy-MM-dd HH:mm:ss"),
            "%Y-%m-%d %H:%M:%S"
        );
    }

    #[test]
    fn absolute_html_attributes_survive_without_a_base_url() {
        assert_eq!(
            absolute_attribute("https://cdn.example/page.jpg".to_owned(), None),
            "https://cdn.example/page.jpg"
        );
        assert_eq!(
            absolute_attribute(
                "/page.jpg".to_owned(),
                Some("https://reader.example/chapter/1")
            ),
            "https://reader.example/page.jpg"
        );
        assert_eq!(
            absolute_attribute("/page.jpg".to_owned(), None),
            "/page.jpg"
        );
    }

    #[test]
    fn absolute_src_uses_lazy_image_url_instead_of_data_placeholder() {
        let document = parse_html(
            r#"<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw="
                data-src="https://mgoimg.view47.com/cover.jpeg">"#,
            Some("https://rawotaku.com/latest-updated".to_owned()),
        );
        let image = select_nodes(&document, "img").unwrap().remove(0);

        assert_eq!(
            html_attribute(&image.node, "src", true).as_deref(),
            Some("https://mgoimg.view47.com/cover.jpeg")
        );
        assert!(
            html_attribute(&image.node, "src", false)
                .as_deref()
                .is_some_and(|value| value.starts_with("data:image/gif"))
        );
    }

    #[test]
    fn canvas_copy_moves_and_scales_the_requested_image_region() {
        let mut source = RgbaImage::new(2, 1);
        source.put_pixel(0, 0, image::Rgba([255, 0, 0, 255]));
        source.put_pixel(1, 0, image::Rgba([0, 0, 255, 255]));
        let mut target = RgbaImage::new(2, 2);

        assert!(copy_bitmap_region(
            &mut target,
            &source,
            1.0,
            0.0,
            1.0,
            1.0,
            0.0,
            0.0,
            2.0,
            2.0,
        ));
        assert_eq!(target.get_pixel(0, 0).0, [0, 0, 255, 255]);
        assert_eq!(target.get_pixel(1, 1).0, [0, 0, 255, 255]);
    }

    #[test]
    fn initializes_source_settings_and_host_defaults() {
        let manifest = json!({
            "info": {
                "id": "multi.example",
                "name": "Example",
                "version": 1,
                "urls": ["https://example.com"],
                "languages": ["ja", "en"]
            }
        });
        let settings = json!([{
            "type": "group",
            "items": [
                {"key": "enabled", "default": true},
                {"key": "ratings", "default": ["safe", "suggestive"]}
            ]
        }]);
        let defaults = package_defaults(&manifest, Some(&settings)).unwrap();
        assert!(postcard::from_bytes::<bool>(&defaults["enabled"]).unwrap());
        assert_eq!(
            postcard::from_bytes::<Vec<String>>(&defaults["ratings"]).unwrap(),
            vec!["safe", "suggestive"]
        );
        assert_eq!(
            postcard::from_bytes::<Vec<String>>(&defaults["languages"]).unwrap(),
            vec!["en"]
        );
        assert_eq!(
            postcard::from_bytes::<String>(&defaults["url"]).unwrap(),
            "https://example.com"
        );
    }

    #[test]
    #[ignore = "requires FUSHI_AIDOKU_TEST_PACKAGE and live source network access"]
    fn live_html_source_can_search_open_details_and_resolve_pages() {
        let path = std::env::var("FUSHI_AIDOKU_TEST_PACKAGE")
            .expect("FUSHI_AIDOKU_TEST_PACKAGE must point to an .aix package");
        let query = std::env::var("FUSHI_AIDOKU_TEST_QUERY")
            .unwrap_or_else(|_| "Sanagi no Heart".to_owned());
        let package = AixPackage::open(path).expect("open live Aidoku package");
        let mut runtime =
            EmbeddedRuntime::load(&package.wasm, package.defaults).expect("load live source");
        let search = runtime.search(Some(&query), 1).expect("search live source");
        assert!(
            search
                .entries
                .iter()
                .filter_map(|manga| manga.cover.as_deref())
                .any(|cover| cover.starts_with("https://")),
            "source search should resolve at least one HTTP cover"
        );
        let details = search
            .entries
            .iter()
            .take(8)
            .filter_map(|manga| runtime.details(manga).ok())
            .find(|details| {
                details
                    .chapters
                    .as_ref()
                    .is_some_and(|chapters| !chapters.is_empty())
            })
            .expect("search results should include a manga with chapters");
        let chapter = details
            .chapters
            .as_ref()
            .and_then(|chapters| chapters.first())
            .expect("manga chapter");
        let pages = runtime
            .pages(&details, chapter)
            .expect("resolve chapter pages");
        assert!(
            !pages.is_empty(),
            "source returned no pages for manga={} chapter={}",
            serde_json::to_string(&details).unwrap(),
            serde_json::to_string(chapter).unwrap()
        );
    }

    #[test]
    #[ignore = "requires FUSHI_AIDOKU_COMPATIBILITY_DIR containing .aix packages"]
    fn compatibility_packages_can_instantiate() {
        let directory = std::env::var("FUSHI_AIDOKU_COMPATIBILITY_DIR")
            .expect("FUSHI_AIDOKU_COMPATIBILITY_DIR must point to a package directory");
        let mut checked = 0;
        let mut failures = Vec::new();
        for entry in std::fs::read_dir(directory).expect("read compatibility directory") {
            let path = entry.expect("read compatibility entry").path();
            if path.extension().and_then(|value| value.to_str()) != Some("aix") {
                continue;
            }
            let package = AixPackage::open(&path)
                .unwrap_or_else(|error| panic!("open {}: {error:#}", path.display()));
            if let Err(error) = EmbeddedRuntime::load(&package.wasm, package.defaults) {
                let engine = Engine::default();
                let module =
                    Module::new(&engine, &package.wasm[..]).unwrap_or_else(|module_error| {
                        panic!("parse {}: {module_error:#}", path.display())
                    });
                let imports = module
                    .imports()
                    .map(|import| format!("{}::{}", import.module(), import.name()))
                    .collect::<Vec<_>>()
                    .join(", ");
                failures.push(format!("{}: {error:#}; imports: {imports}", path.display()));
            }
            checked += 1;
        }
        assert!(
            checked > 0,
            "compatibility directory contained no .aix files"
        );
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }
}
