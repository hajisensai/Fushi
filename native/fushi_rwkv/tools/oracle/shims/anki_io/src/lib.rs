//! Oracle-only shim: the upstream rwkv module calls these only in its
//! resident-state spill path, which the oracle never exercises.
use std::fs::File;
use std::io;
use std::path::Path;
use std::path::PathBuf;

pub struct NamedTemp {
    pub file: File,
    pub path: PathBuf,
}

impl io::Write for NamedTemp {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        io::Write::write(&mut self.file, buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        io::Write::flush(&mut self.file)
    }
}

pub fn new_tempfile_in_parent_of(path: &Path) -> io::Result<NamedTemp> {
    let tmp = path.with_extension("tmp");
    Ok(NamedTemp {
        file: File::create(&tmp)?,
        path: tmp,
    })
}

pub fn atomic_rename(file: NamedTemp, path: &Path, _fsync: bool) -> io::Result<()> {
    let NamedTemp { file, path: tmp } = file;
    drop(file);
    std::fs::rename(&tmp, path)
}

pub fn open_file(path: &Path) -> io::Result<File> {
    File::open(path)
}

pub fn remove_file(path: &Path) -> io::Result<()> {
    std::fs::remove_file(path)
}
