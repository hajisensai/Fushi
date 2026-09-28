// fushi-anki-sync: a small stdin/stdout JSON-lines wrapper around Anki's official
// rslib, so Fushi can add cards to an Anki collection and sync it to a self-hosted
// Anki sync server (or AnkiWeb, if the user explicitly opts in) without Anki installed.
//
// Protocol: one JSON object per line on stdin, one reply per line on stdout:
//   request  {"id": <any>, "cmd": "<name>", ...args}
//   reply    {"id": <same>, "ok": true, "result": {...}} | {"id": ..., "ok": false, "error": "..."}
//
// Data-safety rules (see docs/specs/2026-09-28-anki-pending-mining-and-sync.md):
//   * never full-upload: when the server demands a one-way sync we only ever download;
//   * a fresh local collection must be full-downloaded before the first add_note,
//     otherwise its schema never matches the server and every later sync is blocked;
//   * a full download discards local notes that were not pushed yet — the caller keeps
//     its own queue as the source of truth and replays after a download.
use std::io::{BufRead, Write};

use anki::collection::CollectionBuilder;
use anki::prelude::*;
use anki::search::SearchNode;
use anki::text::strip_html_preserving_media_filenames;
use anki::sync::collection::normal::SyncActionRequired;
use anki::sync::login::{sync_login, SyncAuth};
use anki::sync::media::progress::MediaSyncProgress;
use anki_proto::notes::note_fields_check_response::State as NoteFieldsState;
use reqwest::Url;
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
enum Cmd {
    /// Client identity actually reported to the sync server.
    Version,
    Login {
        endpoint: Option<String>,
        username: String,
        password: String,
    },
    Open {
        path: String,
    },
    Close,
    ListMeta,
    IsDuplicate {
        notetype: String,
        first_field: String,
    },
    /// Notes whose first field matches, with the same rule as `IsDuplicate`.
    FindNotes {
        notetype: String,
        first_field: String,
    },
    /// Which of these (note id, first field) pairs are in the open collection right now.
    ExistingNotes {
        notes: Vec<(i64, String)>,
    },
    AddNote {
        notetype: String,
        deck: String,
        fields: Vec<String>,
        tags: Vec<String>,
        /// (desired file name, local source path)
        media: Vec<(String, String)>,
    },
    Sync {
        hkey: String,
        endpoint: Option<String>,
    },
    FullDownload {
        hkey: String,
        endpoint: Option<String>,
    },
}

#[derive(Deserialize)]
struct Envelope {
    #[serde(default)]
    id: Value,
    #[serde(flatten)]
    cmd: Cmd,
}

struct State {
    col: Option<Collection>,
    path: Option<String>,
    http: reqwest::Client,
    rt: tokio::runtime::Runtime,
}

/// Same normalisation the official backend applies (rslib backend/sync.rs: join("./")).
fn endpoint_url(ep: &Option<String>) -> Result<Option<Url>> {
    ep.as_ref()
        .map(|v| {
            Url::try_from(v.as_str())
                .and_then(|u| u.join("./"))
                .or_invalid("bad endpoint")
        })
        .transpose()
}

fn auth(hkey: String, endpoint: &Option<String>) -> Result<SyncAuth> {
    Ok(SyncAuth {
        hkey,
        endpoint: endpoint_url(endpoint)?,
        io_timeout_secs: None,
    })
}

fn open(path: &str) -> Result<Collection> {
    CollectionBuilder::new(path).with_desktop_media_paths().build()
}

impl State {
    fn col(&mut self) -> Result<&mut Collection> {
        self.col.as_mut().or_invalid("collection not open")
    }

    fn close(&mut self) -> Result<()> {
        if let Some(c) = self.col.take() {
            c.close(None)?;
        }
        Ok(())
    }

    /// `full_download` consumes the collection; the file must be reopened afterwards
    /// whether or not the download succeeded (rslib backend/sync.rs does the same).
    fn full_download(&mut self, a: SyncAuth) -> Result<()> {
        let c = self.col.take().or_invalid("collection not open")?;
        let path = self.path.clone().or_invalid("collection not open")?;
        let r = self.rt.block_on(c.full_download(a, self.http.clone()));
        self.col = Some(open(&path)?);
        r
    }
}

fn list_meta(c: &mut Collection) -> Result<Value> {
    let decks: Vec<String> = c
        .get_all_normal_deck_names(false)?
        .into_iter()
        .map(|(_, n)| n)
        .collect();
    let mut notetypes = vec![];
    for nt in c.get_all_notetypes()? {
        let fields: Vec<String> = nt.fields.iter().map(|f| f.name.clone()).collect();
        notetypes.push(json!({"name": nt.name, "fields": fields}));
    }
    Ok(json!({"decks": decks, "notetypes": notetypes}))
}

fn build_note(c: &mut Collection, notetype: &str, fields: &[String]) -> Result<Note> {
    let nt = c
        .get_notetype_by_name(notetype)?
        .or_not_found(notetype.to_string())?;
    let mut note = nt.new_note();
    for (i, f) in fields.iter().enumerate().take(nt.fields.len()) {
        note.set_field(i, f.clone())?;
    }
    Ok(note)
}

fn is_duplicate(c: &mut Collection, notetype: &str, first: &str) -> Result<bool> {
    let note = build_note(c, notetype, &[first.to_string()])?;
    Ok(c.note_fields_check(&note)? == NoteFieldsState::Duplicate)
}

/// Notes of `notetype` whose first field equals `first` under Anki's own duplicate
/// rule: `dupe:` search = first-field checksum of the HTML-stripped text (media file
/// names kept), then an exact stripped comparison — the same check `note_fields_check`
/// uses, so a note `is_duplicate` reports is always found here. Newest first.
fn find_notes(c: &mut Collection, notetype: &str, first: &str) -> Result<Value> {
    let nt = c
        .get_notetype_by_name(notetype)?
        .or_not_found(notetype.to_string())?;
    if strip_html_preserving_media_filenames(first).trim().is_empty() {
        return Ok(json!({"notes": []}));
    }
    let mut ids = c.search_notes_unordered(SearchNode::Duplicates {
        notetype_id: nt.id,
        text: first.to_string(),
    })?;
    ids.sort_by(|a, b| b.0.cmp(&a.0));
    let mut notes = vec![];
    for nid in ids {
        let Some(note) = c.storage.get_note(nid)? else {
            continue;
        };
        let preview = strip_html_preserving_media_filenames(&note.fields()[0]).into_owned();
        notes.push(json!({"note_id": nid.0, "preview": preview}));
    }
    Ok(json!({ "notes": notes }))
}

/// Note ids from `notes` that exist in this collection **and** still carry the given
/// first field (HTML stripped, media names kept). The caller's journal keeps a card
/// until its id is confirmed here after a successful sync; the first-field check
/// guards against an unrelated note that happens to reuse the id after a full download.
fn existing_notes(c: &mut Collection, notes: &[(i64, String)]) -> Result<Value> {
    let mut existing = vec![];
    for (id, first) in notes {
        let Some(note) = c.storage.get_note(NoteId(*id))? else {
            continue;
        };
        let head = strip_html_preserving_media_filenames(&note.fields()[0]);
        if head == strip_html_preserving_media_filenames(first) {
            existing.push(*id);
        }
    }
    Ok(json!({ "existing": existing }))
}

fn add_note(
    c: &mut Collection,
    notetype: &str,
    deck: &str,
    fields: &[String],
    tags: &[String],
    media: &[(String, String)],
) -> Result<Value> {
    let mgr = c.media()?;
    let mut names = vec![];
    for (want, src) in media {
        let data = std::fs::read(src)
            .ok()
            .or_invalid(format!("cannot read media file {src}"))?;
        names.push(mgr.add_file(want, &data)?.into_owned());
    }
    let mut note = build_note(c, notetype, fields)?;
    note.tags = tags.to_vec();
    let did = c.get_or_create_normal_deck(deck)?.id;
    c.add_note(&mut note, did)?;
    Ok(json!({"note_id": note.id.0, "media": names}))
}

fn sync(st: &mut State, a: SyncAuth) -> Result<Value> {
    let http = st.http.clone();
    // Borrow the fields directly (not via st.col()) so `col` and `rt` are disjoint.
    let out = {
        let c = st.col.as_mut().or_invalid("collection not open")?;
        st.rt.block_on(c.normal_sync(a.clone(), http.clone()))?
    };
    let mut full_download = false;
    if let SyncActionRequired::FullSyncRequired { download_ok, .. } = out.required {
        // Never full-upload: that would overwrite the user's whole collection.
        if !download_ok {
            return Ok(json!({
                "status": "full_sync_blocked",
                "reason": "the server requires a full upload, which Fushi never does",
            }));
        }
        st.full_download(a.clone())?;
        full_download = true;
    }
    // Media is skipped by the official client while a full sync is pending; after a
    // normal sync (or our download) it is safe to run.
    let c = st.col.as_mut().or_invalid("collection not open")?;
    let mgr = c.media()?;
    let progress = c.new_progress_handler::<MediaSyncProgress>();
    st.rt.block_on(mgr.sync_media(progress, a, http, None))?;
    Ok(json!({
        "status": "ok",
        "full_download": full_download,
        "new_endpoint": out.new_endpoint,
        "server_message": out.server_message,
    }))
}

fn handle(st: &mut State, cmd: Cmd) -> Result<Value> {
    match cmd {
        Cmd::Version => Ok(json!({"client": anki::version::fushi_sync_client_version()})),
        Cmd::Login {
            endpoint,
            username,
            password,
        } => {
            let a = st
                .rt
                .block_on(sync_login(username, password, endpoint, st.http.clone()))?;
            Ok(json!({"hkey": a.hkey}))
        }
        Cmd::Open { path } => {
            st.close()?;
            let existed = std::path::Path::new(&path).exists();
            st.col = Some(open(&path)?);
            st.path = Some(path);
            // A collection we just created must be full-downloaded before adding notes.
            Ok(json!({"created": !existed}))
        }
        Cmd::Close => {
            st.close()?;
            Ok(json!({}))
        }
        Cmd::ListMeta => list_meta(st.col()?),
        Cmd::IsDuplicate {
            notetype,
            first_field,
        } => Ok(json!({"duplicate": is_duplicate(st.col()?, &notetype, &first_field)?})),
        Cmd::FindNotes {
            notetype,
            first_field,
        } => find_notes(st.col()?, &notetype, &first_field),
        Cmd::ExistingNotes { notes } => existing_notes(st.col()?, &notes),
        Cmd::AddNote {
            notetype,
            deck,
            fields,
            tags,
            media,
        } => add_note(st.col()?, &notetype, &deck, &fields, &tags, &media),
        Cmd::Sync { hkey, endpoint } => sync(st, auth(hkey, &endpoint)?),
        Cmd::FullDownload { hkey, endpoint } => {
            st.full_download(auth(hkey, &endpoint)?)?;
            Ok(json!({}))
        }
    }
}

fn main() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    // http1_only mirrors the official backend (rslib backend/mod.rs).
    let http = reqwest::Client::builder()
        .http1_only()
        .build()
        .expect("http client");
    let mut st = State {
        col: None,
        path: None,
        http,
        rt,
    };
    let stdout = std::io::stdout();
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Envelope>(&line) {
            Ok(env) => match handle(&mut st, env.cmd) {
                Ok(v) => json!({"id": env.id, "ok": true, "result": v}),
                Err(e) => json!({"id": env.id, "ok": false, "error": format!("{e:?}")}),
            },
            Err(e) => json!({"id": Value::Null, "ok": false, "error": e.to_string()}),
        };
        let mut o = stdout.lock();
        let _ = writeln!(o, "{reply}");
        let _ = o.flush();
    }
    let _ = st.close();
}
