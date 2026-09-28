use std::fs::{self, File};
use std::io::{self, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use crate::core::hash;
use crate::error::{LaneError, Result, infra};

pub fn io_error(what: &str, path: &Path, e: &io::Error) -> LaneError {
    infra(format!("{what} {}: {e}", path.display()))
}

pub fn read(path: &Path) -> Result<Vec<u8>> {
    fs::read(path).map_err(|e| io_error("cannot read", path, &e))
}

pub fn read_opt(path: &Path) -> Result<Option<Vec<u8>>> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(io_error("cannot read", path, &e)),
    }
}

pub fn write(path: &Path, bytes: &[u8]) -> Result<()> {
    fs::write(path, bytes).map_err(|e| io_error("cannot write", path, &e))
}

pub fn append(path: &Path, bytes: &[u8]) -> Result<()> {
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut f| f.write_all(bytes))
        .map_err(|e| io_error("cannot append to", path, &e))
}

pub fn create_dir_all(path: &Path) -> Result<()> {
    fs::create_dir_all(path).map_err(|e| io_error("cannot create", path, &e))
}

pub fn sha256_file(path: &Path) -> Result<String> {
    read(path).map(|bytes| hash::sha256_hex(&bytes))
}

/// The new file has tempfile's mode, 0600.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let name = file_name(path);
    let mut tmp = tempfile::Builder::new()
        .prefix(&format!("{name}."))
        .rand_bytes(6)
        .tempfile_in(dir)
        .map_err(|e| io_error("cannot create a file in", dir, &e))?;
    tmp.write_all(bytes)
        .and_then(|()| tmp.as_file().sync_all())
        .map_err(|e| io_error("cannot write", tmp.path(), &e))?;
    tmp.persist(path)
        .map_err(|e| io_error("cannot replace", path, &e.error))?;
    if let Ok(d) = File::open(dir) {
        let _ = d.sync_all();
    }
    Ok(())
}

fn copy_then_chmod(from: &Path, to: &Path, mode: u32) -> Result<()> {
    let bytes = read(from)?;
    write(to, &bytes)?;
    fs::set_permissions(to, fs::Permissions::from_mode(mode))
        .map_err(|e| io_error("cannot chmod", to, &e))
}

pub fn copy_with_mode(from: &Path, to: &Path) -> Result<()> {
    let mode = fs::metadata(from)
        .map_err(|e| io_error("cannot stat", from, &e))?
        .permissions()
        .mode();
    copy_then_chmod(from, to, mode)
}

pub fn install_0644(from: &Path, to: &Path) -> Result<()> {
    copy_then_chmod(from, to, 0o644)
}

fn sort_by_bytes(paths: &mut [PathBuf]) {
    paths.sort_by(|a, b| {
        a.as_os_str()
            .as_encoded_bytes()
            .cmp(b.as_os_str().as_encoded_bytes())
    });
}

/// As a glob sees them in the C locale: dot entries skipped, sorted by bytes.
pub fn sorted_entries(dir: &Path) -> Result<Vec<PathBuf>> {
    let rd = match fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(io_error("cannot list", dir, &e)),
    };
    let mut out: Vec<PathBuf> = rd
        .filter_map(std::result::Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .is_some_and(|n| !n.as_encoded_bytes().starts_with(b"."))
        })
        .collect();
    sort_by_bytes(&mut out);
    Ok(out)
}

pub fn files_under(dir: &Path, keep: &dyn Fn(&str) -> bool) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let rd = match fs::read_dir(&d) {
            Ok(rd) => rd,
            Err(e) if e.kind() == io::ErrorKind::NotFound && d == dir => return Ok(Vec::new()),
            Err(e) => return Err(io_error("cannot list", &d, &e)),
        };
        for entry in rd {
            let entry = entry.map_err(|e| io_error("cannot list", &d, &e))?;
            let kind = entry
                .file_type()
                .map_err(|e| io_error("cannot stat", &entry.path(), &e))?;
            if kind.is_dir() {
                stack.push(entry.path());
            } else if kind.is_file() && keep(&entry.file_name().to_string_lossy()) {
                out.push(entry.path());
            }
        }
    }
    sort_by_bytes(&mut out);
    Ok(out)
}

pub fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[derive(Debug)]
pub struct StoreLock {
    _file: File,
}

pub fn lock_store(store: &Path) -> Result<StoreLock> {
    create_dir_all(store)?;
    let path = store.join(".lock");
    let file = File::create(&path).map_err(|e| io_error("cannot open", &path, &e))?;
    match file.try_lock() {
        Ok(()) => Ok(StoreLock { _file: file }),
        Err(fs::TryLockError::WouldBlock) => {
            Err(infra(format!("another lane run holds {}", path.display())))
        }
        Err(fs::TryLockError::Error(e)) => Err(io_error("cannot lock", &path, &e)),
    }
}
