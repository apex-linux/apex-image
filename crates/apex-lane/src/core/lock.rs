//! `rpms.lock` and `rpms.lock.next`, format 1: one record per line.

use crate::core::manifest;
use crate::core::names::{nevra_evr, nevra_name};
use crate::core::text;

pub const HEADER: [&str; 5] = [
    "# apex rpms.lock 1: written by apex-lane (packaging/README.md, \"rpms.lock\")",
    "#   family NAME STATE KEY [since=UTC] [limit=UTC] [newer=NVR,...] [security=0|1|?] [reason=TEXT]",
    "#   rpm FAMILY KIND NAME NEVRA SHA256 PATH   (PATH relative to APEX_STORE)",
    "# STATE: built | held (KEY: the last good build) | stock (the owner) | degraded (on_fail=degrade)",
    "# KIND:  built (Apex-built) | mirror (Fedora-signed, unmodified)",
];

fn is_record_of(line: &[u8], record: &[u8], family: &str) -> bool {
    let f = text::fields(line);
    f.first() == Some(&record) && f.get(1) == Some(&family.as_bytes())
}

/// The family's line without `family NAME `: its state, key and attributes. Empty when
/// there is none.
pub fn family_line(lock: &[u8], family: &str) -> Vec<u8> {
    let Some(line) = text::lines(lock)
        .into_iter()
        .find(|line| is_record_of(line, b"family", family))
    else {
        return Vec::new();
    };
    // `sub(/^family [^ ]+ /, "")`: single spaces only, else the whole line.
    if let Some(rest) = line.strip_prefix(b"family ") {
        let name_len = rest.iter().take_while(|&&b| b != b' ').count();
        if name_len > 0 && rest.get(name_len) == Some(&b' ') {
            return rest[name_len + 1..].to_vec();
        }
    }
    line.to_vec()
}

/// The family's rpm lines, each with its newline.
pub fn rpm_lines(lock: &[u8], family: &str) -> Vec<u8> {
    let lines: Vec<&[u8]> = text::lines(lock)
        .into_iter()
        .filter(|line| is_record_of(line, b"rpm", family))
        .collect();
    text::join_lines(&lines)
}

/// An attribute of a family line; `reason=` runs to the end of the line.
pub fn attr(line: &[u8], name: &str) -> Vec<u8> {
    let reason_at = text::find(line, b" reason=");
    if name == "reason" {
        return reason_at.map_or_else(Vec::new, |at| line[at + 8..].to_vec());
    }
    let head = reason_at.map_or(line, |at| &line[..at]);
    let prefix = format!("{name}=");
    text::fields(head)
        .into_iter()
        .find_map(|f| f.strip_prefix(prefix.as_bytes()))
        .map_or_else(Vec::new, <[u8]>::to_vec)
}

/// FAMILY's records go last; the others keep their bytes and order. The image's content key
/// hashes the lock, so the bytes matter.
pub fn put(old: Option<&[u8]>, family: &str, line: &[u8], rpms: &[u8]) -> Vec<u8> {
    let mut out = text::join_lines(&HEADER);
    for kept in old.map(text::lines).unwrap_or_default() {
        let f = text::fields(kept);
        if kept.starts_with(b"#") || f.is_empty() {
            continue;
        }
        if (f[0] == b"family" || f[0] == b"rpm") && f.get(1) == Some(&family.as_bytes()) {
            continue;
        }
        out.extend_from_slice(kept);
        out.push(b'\n');
    }
    out.extend_from_slice(format!("family {family} ").as_bytes());
    out.extend_from_slice(line);
    out.push(b'\n');
    out.extend_from_slice(rpms);
    out
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("manifest {manifest}: bad NEVRA '{nevra}'")]
pub struct BadNevra {
    pub manifest: String,
    pub nevra: String,
}

/// The lock lines of a stored set: its built RPMs named by `install` (once per name
/// listed), then every mirror RPM, in manifest order. `dev` RPMs are never locked.
pub fn manifest_lock_rpms(
    label: &str,
    manifest_text: &[u8],
    family: &str,
    keypath: &str,
    install: &[String],
) -> Result<Vec<u8>, BadNevra> {
    let mut out = Vec::new();
    for e in manifest::entries(manifest_text) {
        if e.kind != b"built" && e.kind != b"mirror" {
            continue;
        }
        let name = nevra_name(e.nevra).ok_or_else(|| BadNevra {
            manifest: label.to_owned(),
            nevra: text::lossy(e.nevra),
        })?;
        let line = |kind: &str| {
            let mut l = format!("rpm {family} {kind} ").into_bytes();
            for (i, part) in [name, e.nevra, e.sha256].iter().enumerate() {
                if i > 0 {
                    l.push(b' ');
                }
                l.extend_from_slice(part);
            }
            l.extend_from_slice(format!(" {keypath}/").as_bytes());
            l.extend_from_slice(e.file);
            l.push(b'\n');
            l
        };
        if e.kind == b"built" {
            for want in install {
                if want.as_bytes() == name {
                    out.extend(line("built"));
                }
            }
        } else {
            out.extend(line("mirror"));
        }
    }
    Ok(out)
}

/// How many of `rpms` (lock lines) are Apex-built.
pub fn built_count(rpms: &[u8]) -> usize {
    text::lines(rpms)
        .into_iter()
        .filter(|l| text::fields(l).get(2) == Some(&&b"built"[..]))
        .count()
}

/// The EVR of the family's main package in the lock, no epoch when it is 0; empty when
/// there is none.
pub fn locked_evr(lock: &[u8], family: &str, srpm: &str) -> Vec<u8> {
    let rpms = rpm_lines(lock, family);
    text::lines(&rpms)
        .into_iter()
        .map(text::fields)
        .find(|f| f.get(2) == Some(&&b"built"[..]) && f.get(3) == Some(&srpm.as_bytes()))
        .map(|f| nevra_evr(f.get(4).copied().unwrap_or_default()))
        .unwrap_or_default()
}

/// `(sha256, path)` of every rpm line (`grep '^rpm ' | read -r _ _ _ _ _ sha path`).
pub fn rpm_files(lock: &[u8]) -> Vec<(Vec<u8>, Vec<u8>)> {
    text::lines(lock)
        .into_iter()
        .filter(|line| line.starts_with(b"rpm "))
        .map(|line| {
            let f = text::read_fields(line, 7);
            (f[5].to_vec(), f[6].to_vec())
        })
        .collect()
}

/// A store path as image.sh accepts it: relative, with no `..` component.
pub fn is_store_path(path: &[u8]) -> bool {
    !path.is_empty() && !path.starts_with(b"/") && !path.split(|&b| b == b'/').any(|c| c == b"..")
}
