// Copyright: Fushi contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

use super::*;
use sha2::{Digest, Sha256};
use std::path::PathBuf;

fn model(small: bool) -> Model {
    let (filename, expected) = if small {
        ("sm56-package.zip", SMALL_MODEL_PACKAGE_SHA256)
    } else {
        ("RWKV_trained_on_5000_10000.bin", MODEL_SHA256)
    };
    let variable = if small { "FUSHI_RWKV_SMALL_PACKAGE" } else { "FUSHI_RWKV_MODEL" };
    let path = std::env::var_os(variable).map(PathBuf::from).unwrap_or_else(||
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("model").join(filename));
    let bytes = std::fs::read(&path).unwrap_or_else(|error| panic!("missing model {}: {error}", path.display()));
    assert_eq!(format!("{:x}", Sha256::digest(&bytes)), expected);
    if small {
        use std::io::Read;
        let mut archive = zip::ZipArchive::new(io::Cursor::new(bytes)).unwrap();
        let mut weights = Vec::new();
        archive.by_name("sm56/weights.int8.bin").unwrap().read_to_end(&mut weights).unwrap();
        Model::from_bytes(&weights).unwrap()
    } else {
        Model::from_bytes(&bytes).unwrap()
    }
}

fn row(card: i64, day: i64, query: bool) -> ReviewInput {
    ReviewInput {
        card_id: card,
        note_id: Some(card / 2),
        deck_id: Some(1),
        preset_id: Some(1),
        is_query: query,
        ease: if query { None } else { Some(3) },
        duration_millis: Some(1500),
        card_type: Some(if day == 0 { 0 } else { 2 }),
        day_offset: Some(day),
        current_elapsed_days: Some(if day == 0 { -1 } else { 1 }),
        current_elapsed_seconds: Some(if day == 0 { -1 } else { 86400 }),
    }
}

struct Directory(PathBuf);

impl Directory {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("fushi-rwkv-快照-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn round_trip(small: bool) {
    let model = model(small);
    let directory = Directory::new(if small { "small" } else { "large" });
    let path = directory.0.join("模型状态.bin");
    let precisions: &[StatePrecision] = if small {
        &[StatePrecision::F32, StatePrecision::Int8, StatePrecision::Int4]
    } else {
        &[StatePrecision::F32, StatePrecision::Int8]
    };
    for &precision in precisions {
        let mut original = RwkvRuntime::new(&model, precision, 1).unwrap();
        let reviews: Vec<_> = (0..2).flat_map(|day| (1..=4).map(move |card| row(card, day, false))).collect();
        original.replay(&reviews, false).unwrap();
        let expected = match &original.inference {
            Engine::Small(engine) => engine.legacy_snapshot(),
            Engine::Large(engine) => engine.legacy_snapshot(),
        };
        assert_eq!(original.snapshot().unwrap(), expected, "legacy byte format changed");
        original.snapshot_to_file(&path).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), expected);
        let mut restored = RwkvRuntime::new(&model, precision, 1).unwrap();
        restored.restore_from_file(&path).unwrap();
        assert_eq!(restored.snapshot().unwrap(), expected);
        let queries: Vec<_> = (1..=4).map(|card| row(card, 3, true)).collect();
        assert_eq!(original.query(&queries).unwrap(), restored.query(&queries).unwrap());
        // Continuing replay after restore must also be bit-identical.
        let answers: Vec<_> = (1..=4).map(|card| row(card, 3, false)).collect();
        original.replay(&answers, false).unwrap();
        restored.replay(&answers, false).unwrap();
        assert_eq!(original.snapshot().unwrap(), restored.snapshot().unwrap());

        if small {
            restored.append(&[row(9, 4, false)], &[123], &[1]).unwrap();
        }
        restored.scores_update(&queries.iter().map(|q| row(q.card_id, 5, true)).collect::<Vec<_>>(), &[1; 4], &[0; 4]).unwrap();
        let old_state = restored.inference.snapshot();
        let old_journal = restored.journal_len();
        let old_scores = restored.scores_lookup(&[1, 2, 3, 4], &[1; 4]);
        assert_eq!(restored.scores_len(), 4);
        assert_eq!(old_journal > 0, small);
        restored.poisoned = true;
        let mut corrupt: Vec<Vec<u8>> = [0, 1, 10, 20, expected.len() / 2, expected.len() - 1]
            .into_iter().map(|len| expected[..len].to_vec()).collect();
        let mut trailing = expected.clone();
        trailing.push(0);
        corrupt.push(trailing);
        let mut magic = expected.clone();
        magic[0] ^= 1;
        corrupt.push(magic);
        let mut wrong_precision = expected.clone();
        wrong_precision[if small { 12 } else { 11 }] = 99;
        corrupt.push(wrong_precision);
        let count_at = if small { 25 } else { 12 };
        let mut count = expected.clone();
        count[count_at..count_at + 4].copy_from_slice(&u32::MAX.to_le_bytes());
        corrupt.push(count);
        let (first_id, second_id, state_start) = if small {
            let slot = u32::from_le_bytes(expected[21..25].try_into().unwrap()) as usize;
            (29, 37 + slot, 37)
        } else {
            let len = u32::from_le_bytes(expected[24..28].try_into().unwrap()) as usize;
            (16, 28 + len, 28)
        };
        let mut duplicate = expected.clone();
        duplicate[second_id..second_id + 8].copy_from_slice(&expected[first_id..first_id + 8]);
        corrupt.push(duplicate);
        let mut state = expected.clone();
        if small {
            state[state_start..state_start + 4].copy_from_slice(&f32::NAN.to_le_bytes());
        } else {
            state[state_start] ^= 1;
        }
        corrupt.push(state);
        let mut bad_size = expected.clone();
        let size_at = if small { 21 } else { 24 };
        bad_size[size_at..size_at + 4].copy_from_slice(&u32::MAX.to_le_bytes());
        corrupt.push(bad_size);
        if small {
            let mut fingerprint = expected.clone();
            fingerprint[13] ^= 1;
            corrupt.push(fingerprint);
        }
        for bytes in corrupt {
            std::fs::write(&path, &bytes).unwrap();
            assert!(restored.restore_from_file(&path).is_err(), "accepted corrupt file");
            assert!(restored.restore(&bytes).is_err(), "byte API accepted corrupt data");
            assert_eq!(restored.inference.snapshot(), old_state);
            assert!(restored.poisoned);
            assert_eq!(restored.journal_len(), old_journal);
            assert_eq!(restored.scores_lookup(&[1, 2, 3, 4], &[1; 4]), old_scores);
        }
        for missing_or_directory in [directory.0.join("missing"), directory.0.clone()] {
            assert!(restored.restore_from_file(&missing_or_directory).is_err());
            assert_eq!(restored.inference.snapshot(), old_state);
            assert!(restored.poisoned);
            assert_eq!(restored.journal_len(), old_journal);
            assert_eq!(restored.scores_lookup(&[1, 2, 3, 4], &[1; 4]), old_scores);
        }
        assert_eq!(restored.snapshot_to_file(&path), Err(RwkvError::Poisoned));
        restored.poisoned = false;
        assert!(restored.snapshot_to_file(&directory.0).is_err());
        assert_eq!(restored.inference.snapshot(), old_state);
        assert_eq!(restored.journal_len(), old_journal);
        assert_eq!(restored.scores_lookup(&[1, 2, 3, 4], &[1; 4]), old_scores);
        restored.poisoned = true;
        std::fs::write(&path, &expected).unwrap();
        restored.restore_from_file(&path).unwrap();
        assert!(!restored.poisoned);
        assert_eq!(restored.journal_len(), 0);
        assert_eq!(restored.scores_len(), 0);
        assert_eq!(restored.snapshot().unwrap(), expected);
    }
}

/// An I/O failure during the final EOF check must not commit parsed stores.
struct FailingReader<'a> {
    bytes: &'a [u8],
    fail_after: usize,
}

impl io::Read for FailingReader<'_> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.fail_after == 0 {
            return Err(io::Error::other("injected read failure"));
        }
        let len = out.len().min(self.bytes.len()).min(self.fail_after);
        out[..len].copy_from_slice(&self.bytes[..len]);
        self.bytes = &self.bytes[len..];
        self.fail_after -= len;
        Ok(len)
    }
}

#[test]
fn streaming_io_errors_before_commit_preserve_both_models() {
    for small in [true, false] {
        let model = model(small);
        let mut source = RwkvRuntime::new(&model, StatePrecision::Int8, 1).unwrap();
        source.replay(&[row(1, 0, false)], false).unwrap();
        let snapshot = source.snapshot().unwrap();
        let mut target = RwkvRuntime::new(&model, StatePrecision::Int8, 1).unwrap();
        let empty = target.snapshot().unwrap();
        for fail_after in [snapshot.len() / 2, snapshot.len()] {
            let mut input = FailingReader { bytes: &snapshot, fail_after };
            assert!(target.inference.read_snapshot(&mut input, snapshot.len() as u64).is_err());
            assert_eq!(target.snapshot().unwrap(), empty);
        }
    }
}

#[test]
fn small_snapshot_files_are_lossless_and_atomic() {
    round_trip(true);
}

#[test]
fn large_snapshot_files_are_lossless_and_atomic() {
    round_trip(false);
}

#[test]
fn file_c_abi_accepts_unicode_and_rejects_invalid_arguments() {
    let model = model(true);
    let mut runtime = FrwkvRuntime(RwkvRuntime::new(&model, StatePrecision::Int4, 1).unwrap());
    runtime.0.replay(&[row(1, 0, false)], false).unwrap();
    let expected = runtime.0.snapshot().unwrap();
    let directory = Directory::new("ffi");
    let path = directory.0.join("保存.bin");
    let path = path.to_str().unwrap().as_bytes();
    unsafe {
        assert_eq!(frwkv_runtime_snapshot_to_file(&runtime, path.as_ptr(), path.len()), FRWKV_OK);
        runtime.0.reset();
        assert_eq!(frwkv_runtime_restore_from_file(&mut runtime, path.as_ptr(), path.len()), FRWKV_OK);
        assert_eq!(runtime.0.snapshot().unwrap(), expected);
        assert_ne!(frwkv_runtime_snapshot_to_file(std::ptr::null(), path.as_ptr(), path.len()), FRWKV_OK);
        assert_ne!(frwkv_runtime_restore_from_file(&mut runtime, std::ptr::null(), 1), FRWKV_OK);
        assert_ne!(frwkv_runtime_restore_from_file(&mut runtime, [255].as_ptr(), 1), FRWKV_OK);
        assert_eq!(runtime.0.snapshot().unwrap(), expected);
    }
}
