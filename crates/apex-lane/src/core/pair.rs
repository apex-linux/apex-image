//! The kernel and NVIDIA pair (ADR 0015 §4): which side moves, the holds and their clocks,
//! and the formats of pair.sh's `pair.lock` and bump.sh's report.

use std::fmt::Write as _;

use crate::core::hold::{self, Security, Timer};
use crate::core::lock;
use crate::core::pins::{KernelPins, Nevra, major_of};
use crate::core::text;
use crate::core::utc::UtcSecond;

pub const KEY_SCHEMA: u32 = 1;
const KERNEL_HOLD_HOURS: i64 = 72;
const KMOD_POINT_HOLD_HOURS: i64 = 72;
const KMOD_MAJOR_HOLD_DAYS: i64 = 14;
/// K7: a pinned key's expiry is announced well before it stops every verification.
const KEY_WARN_DAYS: i64 = 60;
const KEY_URGENT_DAYS: i64 = 14;
/// ARCHITECTURE 4.2: a pair whose module count moves more than this from the last good
/// pair's is held, as a check failure.
const MODULE_DRIFT_PERCENT: usize = 5;
pub const DEGRADED_NVIDIA: &str = "degraded=nvidia";

/// pair.sh's reason prefixes. Anything but `kmod:` stops the kernel itself: an input
/// check, `kernel:` and `check:` alike.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Kernel,
    Kmod,
}

impl Side {
    pub fn of_reason(reason: &[u8]) -> Self {
        if reason.starts_with(b"kmod:") {
            Self::Kmod
        } else {
            Self::Kernel
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Kernel => "kernel",
            Self::Kmod => "kmod",
        }
    }
}

/// What differs from the last good pair. With both sides new, the kernel goes first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Moves {
    pub kernel: bool,
    pub driver: bool,
    pub new_major: bool,
}

impl Moves {
    pub fn of(good: Option<(&KernelPins, &[u8])>, kernel: &KernelPins, nvidia: &[u8]) -> Self {
        match good {
            None => Self {
                kernel: true,
                driver: true,
                new_major: false,
            },
            Some((good_kernel, good_nvidia)) => Self {
                kernel: good_kernel.srpm != kernel.srpm
                    || good_kernel.srpm_sha256 != kernel.srpm_sha256,
                driver: good_nvidia != nvidia,
                new_major: good_kernel.major() != kernel.major(),
            },
        }
    }

    pub fn driver_waits(self) -> bool {
        self.kernel && self.driver
    }
}

pub fn preimage(pkg: &str, tool: &str, repos: &str, files: &[(String, String)]) -> String {
    let mut out =
        format!("apex lane pair key {KEY_SCHEMA}\npkg {pkg}\nlane {tool}\nrepos {repos}\n");
    for (path, sha) in files {
        let _ = writeln!(out, "file {path} {sha}");
    }
    out
}

/// A kernel-only set may never take the key of the whole pair it stands in for.
pub fn degraded_preimage(pair_preimage: &str) -> String {
    format!("{pair_preimage}{DEGRADED_NVIDIA}\n")
}

/// The hold clock (ARCHITECTURE 4.3): a kernel failure from the kernel.org release (or
/// from the first failure when that is unknown), a kmod failure from the first failure.
pub fn timer(
    side: Side,
    moves: Moves,
    since: UtcSecond,
    released: Option<UtcSecond>,
) -> Option<Timer> {
    if !moves.kernel {
        return None;
    }
    Some(match side {
        Side::Kernel => Timer {
            limit: released.unwrap_or(since).add_hours(KERNEL_HOLD_HOURS),
            security: Security::Yes,
        },
        Side::Kmod if moves.new_major => Timer {
            limit: since.add_days(KMOD_MAJOR_HOLD_DAYS),
            security: Security::No,
        },
        Side::Kmod => Timer {
            limit: since.add_hours(KMOD_POINT_HOLD_HOURS),
            security: Security::Yes,
        },
    })
}

/// As `hold::since`, and a degraded line counts too: its kernel-only set ships the hold.
pub fn since(next_current: &[u8], newer_csv: &str, now: UtcSecond) -> Vec<u8> {
    if is_degraded(next_current) && lock::attr(next_current, "newer") == newer_csv.as_bytes() {
        let since = lock::attr(next_current, "since");
        if !since.is_empty() {
            return since;
        }
    }
    hold::since(next_current, newer_csv, now)
}

pub fn is_degraded(line: &[u8]) -> bool {
    line.starts_with(b"built ") && lock::attr(line, "degraded") == b"nvidia"
}

fn attrs(since: &[u8], newer_csv: &str, timer: Option<&Timer>) -> Vec<u8> {
    let mut out = b" since=".to_vec();
    out.extend_from_slice(since);
    if let Some(t) = timer {
        out.extend_from_slice(format!(" limit={}", t.limit).as_bytes());
    }
    if !newer_csv.is_empty() {
        out.extend_from_slice(format!(" newer={newer_csv}").as_bytes());
    }
    if let Some(t) = timer {
        out.extend_from_slice(format!(" security={}", t.security.as_str()).as_bytes());
    }
    out
}

/// `held GOOD since= [limit=] [newer=] [security=] [degraded=nvidia] side= reason=`:
/// image.sh reads the first four fields, status and the image labels the rest.
pub fn held_line(
    good: (&str, bool),
    since: &[u8],
    newer_csv: &str,
    timer: Option<&Timer>,
    side: Side,
    reason: &[u8],
) -> Vec<u8> {
    let (good_key, good_degraded) = good;
    let mut line = format!("held {good_key}").into_bytes();
    line.extend(attrs(since, newer_csv, timer));
    if good_degraded {
        line.extend_from_slice(format!(" {DEGRADED_NVIDIA}").as_bytes());
    }
    line.extend_from_slice(format!(" side={} reason=", side.as_str()).as_bytes());
    line.extend_from_slice(reason);
    line
}

pub fn degraded_line(
    key: &str,
    since: &[u8],
    newer_csv: &str,
    timer: Option<&Timer>,
    reason: &[u8],
) -> Vec<u8> {
    let mut line = format!("built {key}").into_bytes();
    line.extend(attrs(since, newer_csv, timer));
    line.extend_from_slice(format!(" {DEGRADED_NVIDIA} side=kmod reason=").as_bytes());
    line.extend_from_slice(reason);
    line
}

/// The families `next` locks with `degraded=nvidia` that `locked` does not.
pub fn newly_degraded(locked: &[u8], next: &[u8]) -> Vec<String> {
    text::lines(next)
        .into_iter()
        .filter_map(|line| {
            let f = text::fields(line);
            (f.first() == Some(&&b"family"[..]))
                .then(|| text::lossy(f.get(1).copied().unwrap_or_default()))
        })
        .filter(|family| {
            is_degraded(&lock::family_line(next, family))
                && !is_degraded(&lock::family_line(locked, family))
        })
        .collect()
}

/// A pinned key with an expiry date: the pins' `*_key_expires`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinnedKey {
    pub what: &'static str,
    pub fingerprint: String,
    pub expires: String,
}

pub fn pinned_keys(kernel: &KernelPins, nvidia: &crate::core::pins::NvidiaPins) -> Vec<PinnedKey> {
    let key = |what, fingerprint: &str, expires: &Option<String>| {
        expires.as_ref().map(|expires| PinnedKey {
            what,
            fingerprint: fingerprint.to_owned(),
            expires: expires.clone(),
        })
    };
    [
        key("the COPR key", &kernel.copr_key, &kernel.copr_key_expires),
        key(
            "the CachyOS tag key",
            kernel.tag_key.as_deref().unwrap_or("?"),
            &kernel.tag_key_expires,
        ),
        key(
            "negativo17's key",
            &nvidia.negativo17_key,
            &nvidia.negativo17_key_expires,
        ),
    ]
    .into_iter()
    .flatten()
    .collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyExpiry {
    Fine,
    Warn(String),
    Urgent(String),
    Expired(String),
}

/// Days are counted to the start of the expiry date, UTC.
pub fn key_expiry(key: &PinnedKey, now: UtcSecond) -> KeyExpiry {
    let Some(at) = UtcSecond::parse(format!("{}T00:00:00Z", key.expires).as_bytes()) else {
        return KeyExpiry::Fine;
    };
    let days = (at.0 - now.0).div_euclid(86_400);
    let named = format!(
        "{} {} expires on {}",
        key.what, key.fingerprint, key.expires
    );
    if now >= at {
        KeyExpiry::Expired(format!(
            "{} {} expired on {}: pin its successor, checked against a second source",
            key.what, key.fingerprint, key.expires
        ))
    } else if days < KEY_URGENT_DAYS {
        KeyExpiry::Urgent(format!("{named}, in {days} days: pin its successor now"))
    } else if days < KEY_WARN_DAYS {
        KeyExpiry::Warn(format!("{named}, in {days} days"))
    } else {
        KeyExpiry::Fine
    }
}

/// Kernel modules in an `rpm -qlp` listing of the pair's RPMs.
pub fn count_modules(listing: &[u8]) -> usize {
    text::lines(listing)
        .into_iter()
        .filter(|path| {
            let path = text::lossy(path);
            let in_modules =
                path.starts_with("/lib/modules/") || path.starts_with("/usr/lib/modules/");
            let name = path.rsplit('/').next().unwrap_or_default();
            in_modules
                && [".ko", ".ko.xz", ".ko.zst", ".ko.gz"]
                    .iter()
                    .any(|ext| name.len() > ext.len() && name.ends_with(ext))
        })
        .count()
}

/// `check:`, pair.sh's own prefix for a failed gate, when the count moved too far.
pub fn module_drift(previous: usize, now: usize, good_key: &str) -> Option<String> {
    (previous.abs_diff(now) * 100 > previous * MODULE_DRIFT_PERCENT).then(|| {
        format!(
            "check: the pair has {now} modules, the last good pair {good_key} {previous}: more than {MODULE_DRIFT_PERCENT} % apart"
        )
    })
}

/// The last line of pair.sh's stderr that says something, as `hold::reason_of` cleans it.
pub fn reason_of_stderr(stderr: &[u8]) -> Vec<u8> {
    let last = text::lines(stderr)
        .into_iter()
        .rev()
        .find(|l| !text::trim_end_space(l).is_empty())
        .unwrap_or_default();
    hold::reason_of(Some(last))
}

/// pair.sh's `pair.lock`, or the kernel-only `kernel.lock` (no `kmod=`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairLock {
    pub kernel: Nevra,
    pub kmod: Option<Nevra>,
    pub module_cert_sha256: String,
    pub rpms: Vec<(String, String)>,
}

pub fn parse_pair_lock(bytes: &[u8], want_kmod: bool) -> Result<PairLock, String> {
    let (mut kernel, mut kmod, mut cert, mut rpms) = (None, None, None, Vec::new());
    for line in text::lines(bytes) {
        let line = text::lossy(line);
        let Some((key, value)) = line.split_once('=') else {
            return Err(format!("'{line}' is not KEY=VALUE"));
        };
        let nevra = || Nevra::parse(value).ok_or_else(|| format!("{key}={value} is not a NEVRA"));
        match key {
            "kernel" if kernel.is_none() => kernel = Some(nevra()?),
            "kmod" if kmod.is_none() => kmod = Some(nevra()?),
            "module_cert_sha256" if cert.is_none() => cert = Some(value.to_owned()),
            "rpm" => match value.split_once(' ') {
                Some((file, sha))
                    if is_rpm_file(file)
                        && sha.len() == 64
                        && sha.bytes().all(|c| c.is_ascii_hexdigit()) =>
                {
                    rpms.push((file.to_owned(), sha.to_owned()));
                }
                _ => return Err(format!("rpm={value} is not 'FILE.rpm SHA256'")),
            },
            _ => return Err(format!("unexpected or repeated '{key}'")),
        }
    }
    let kernel = kernel.ok_or("no kernel=")?;
    if want_kmod != kmod.is_some() {
        return Err(if want_kmod {
            "no kmod="
        } else {
            "a kernel.lock with kmod="
        }
        .into());
    }
    if rpms.is_empty() {
        return Err("no rpm=".into());
    }
    Ok(PairLock {
        kernel,
        kmod,
        module_cert_sha256: cert.ok_or("no module_cert_sha256=")?,
        rpms,
    })
}

fn is_rpm_file(file: &str) -> bool {
    file.strip_suffix(".rpm")
        .is_some_and(|stem| !stem.is_empty())
        && !file.starts_with('.')
        && file
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._+~^-".contains(&c))
}

/// kernel-spec.patch's release: `.apexN` goes before the `.fcNN` dist part.
pub fn apex_release(srpm_release: &str, n: u32) -> String {
    match srpm_release.rsplit_once('.') {
        Some((head, dist)) if dist.starts_with("fc") => format!("{head}.apex{n}.{dist}"),
        _ => format!("{srpm_release}.apex{n}"),
    }
}

/// A rehearsal's RPMs are signed with the production key: their N never meets a real one.
pub const REHEARSAL_RELEASE_FLOOR: u32 = 9000;

/// The N of a pair key in the store's ledger of `NVR KEY N` lines: the key's own, or
/// one past the NVR's highest. The ledger outlives pruned sets, so no N is used twice.
pub fn release_number(
    ledger: &[u8],
    nvr: &str,
    key: &str,
    rehearsal: bool,
) -> Result<(u32, bool), String> {
    let mut highest = 0;
    for line in text::lines(ledger) {
        let line = text::lossy(line);
        let fields: Vec<&str> = line.split(' ').collect();
        let [line_nvr, line_key, n] = fields[..] else {
            return Err(format!("'{line}' is not 'NVR KEY N'"));
        };
        let n: u32 = n
            .parse()
            .ok()
            .filter(|&n| n > 0)
            .ok_or_else(|| format!("'{line}': N is not a positive integer"))?;
        if line_key == key {
            return release_in_range(n, rehearsal).map(|()| (n, false));
        }
        if line_nvr == nvr {
            highest = highest.max(n);
        }
    }
    let first = if rehearsal {
        REHEARSAL_RELEASE_FLOOR + 1
    } else {
        1
    };
    let n = (highest + 1).max(first);
    release_in_range(n, rehearsal).map(|()| (n, true))
}

fn release_in_range(n: u32, rehearsal: bool) -> Result<(), String> {
    match (rehearsal, n >= REHEARSAL_RELEASE_FLOOR) {
        (false, true) => Err(format!(
            "N={n} is a rehearsal's (from {REHEARSAL_RELEASE_FLOOR}) in the lane's own store"
        )),
        (true, false) => Err(format!(
            "N={n} is below {REHEARSAL_RELEASE_FLOOR} in a rehearsal, where it could meet a real build"
        )),
        _ => Ok(()),
    }
}

/// bump.sh's report: a point line, a major line, or both, the point first; or `none`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BumpReport {
    pub point: Option<Nevra>,
    /// The new major's SRPM and the pinned major's EOL countdown (`12d`, `unknown`).
    pub major: Option<(Nevra, String)>,
    /// `nvidia NEVRA SHA256 newer`: builds newer than the pins, which wait for the owner.
    pub nvidia_newer: Vec<String>,
    pub nvidia_missing: Vec<String>,
}

pub fn parse_bump(out: &[u8]) -> Result<BumpReport, String> {
    let srpm = |s: &str| {
        Nevra::parse(s)
            .filter(|n| n.arch == "src")
            .ok_or_else(|| format!("bump.sh named '{s}', not an SRPM NEVRA"))
    };
    let mut report = BumpReport {
        point: None,
        major: None,
        nvidia_newer: Vec::new(),
        nvidia_missing: Vec::new(),
    };
    let mut kernel_lines = 0;
    let mut none = false;
    for (i, line) in text::lines(out).into_iter().enumerate() {
        let line = text::lossy(line);
        let kernel_section = i == kernel_lines;
        match line.split(' ').collect::<Vec<_>>()[..] {
            ["point", nevra] if i == 0 => report.point = Some(srpm(nevra)?),
            ["major", nevra, "waiting-for-owner", eol]
                if kernel_section && report.major.is_none() && !none =>
            {
                let eol = eol
                    .strip_prefix("EOL-in-")
                    .ok_or_else(|| format!("bump.sh printed '{line}'"))?;
                report.major = Some((srpm(nevra)?, eol.to_owned()));
            }
            ["none"] if i == 0 => none = true,
            ["nvidia", nevra, _, "newer"] if i > 0 => report.nvidia_newer.push(nevra.to_owned()),
            ["nvidia", _, _, "pinned" | "older"] if i > 0 => {}
            ["nvidia", name, "missing"] if i > 0 => report.nvidia_missing.push(name.to_owned()),
            _ => return Err(format!("bump.sh printed '{line}' as line {}", i + 1)),
        }
        if kernel_section && !line.starts_with("nvidia ") {
            kernel_lines += 1;
        }
    }
    if kernel_lines == 0 {
        return Err("bump.sh printed no kernel line".into());
    }
    Ok(report)
}

/// A point bump keeps the major, so only the pins of the SRPM and its tag move.
/// The `CachyOS` tag of an SRPM: its release starts with the tag's number.
pub fn tag_of(srpm: &Nevra) -> String {
    format!(
        "cachyos-{}-{}",
        srpm.version,
        srpm.release.split('.').next().unwrap_or_default()
    )
}

pub fn bumped_kernel_env(old: &[u8], srpm: &Nevra, sha256: &str) -> Vec<u8> {
    let tag = tag_of(srpm);
    let mut out = Vec::with_capacity(old.len());
    for line in text::lines(old) {
        let replaced = if line.starts_with(b"srpm=") {
            Some(format!("srpm={srpm}"))
        } else if line.starts_with(b"srpm_sha256=") {
            Some(format!("srpm_sha256={sha256}"))
        } else if line.starts_with(b"tag=") {
            Some(format!("tag={tag}"))
        } else {
            None
        };
        match replaced {
            Some(r) => out.extend_from_slice(r.as_bytes()),
            None => out.extend_from_slice(line),
        }
        out.push(b'\n');
    }
    out
}

pub fn is_point_of(pinned: &KernelPins, srpm: &Nevra) -> bool {
    srpm.name == pinned.srpm.name && major_of(&srpm.version) == pinned.major()
}

pub fn summary_held(
    pkg: &str,
    reason: &[u8],
    good_key: &str,
    since: &[u8],
    timer: Option<&Timer>,
    side: Side,
    limit_without_kernel: bool,
) -> Vec<String> {
    let clock = match (timer, side) {
        (None, _) => "The running kernel did not move, so the hold has no limit: the last good pair keeps working.".to_owned(),
        (Some(t), Side::Kernel) => format!(
            "Limit: {} (72 h from the kernel.org release). Then the owner chooses: wait, or the break-glass image.",
            t.limit
        ),
        (Some(t), Side::Kmod) => format!(
            "Limit: {}. Then the image takes the new kernel with {DEGRADED_NVIDIA}, which publishes only with the owner's override.",
            t.limit
        ),
    };
    let mut note = format!(
        "The next image keeps the last good pair, {good_key}, held since {}. {clock}",
        text::lossy(since)
    );
    if limit_without_kernel {
        note.push_str(" LIMIT REACHED, but the pair job kept no kernel (kernel.lock), so the pair stays held.");
    }
    vec![
        format!("### {pkg}: held ({})", side.as_str()),
        String::new(),
        text::lossy(reason),
        String::new(),
        note,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::pins::parse_kernel;

    const KERNEL_ENV: &str = "copr=bieszczaders/kernel-cachyos\nchroot=fedora-45-x86_64\nsrpm=kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src\nsrpm_sha256=e6b57189499ce41b78255deadc86f38e318e24e895283b7e1f412a23de9cf49f\ncopr_key=537DEED33436B0367F5B26D5B3E3132CF10859CF\ntag=cachyos-7.3.0-4\n";

    fn kernel(version: &str) -> KernelPins {
        let text = KERNEL_ENV.replace("7.3.0-4", version);
        parse_kernel("kernel.env", text.as_bytes()).unwrap()
    }

    fn at(s: &str) -> UtcSecond {
        UtcSecond::parse(s.as_bytes()).unwrap()
    }

    #[test]
    fn the_kernel_moves_first() {
        let old = kernel("7.3.0-4");
        let m = Moves::of(Some((&old, b"d1")), &kernel("7.3.1-1"), b"d2");
        assert!(m.kernel && m.driver && m.driver_waits() && !m.new_major);
        let m = Moves::of(Some((&old, b"d1")), &kernel("7.4.0-1"), b"d1");
        assert!(m.kernel && !m.driver && m.new_major && !m.driver_waits());
        let m = Moves::of(Some((&old, b"d1")), &old, b"d2");
        assert!(!m.kernel && m.driver);
    }

    #[test]
    fn hold_clocks() {
        let since = at("2026-12-01T00:00:00Z");
        let released = Some(at("2026-11-30T12:00:00Z"));
        let point = Moves {
            kernel: true,
            driver: false,
            new_major: false,
        };
        let major = Moves {
            new_major: true,
            ..point
        };
        let driver = Moves {
            kernel: false,
            driver: true,
            new_major: false,
        };
        let limit = |side, moves, released| {
            timer(side, moves, since, released).map(|t| t.limit.to_string())
        };
        assert_eq!(
            limit(Side::Kernel, point, released).as_deref(),
            Some("2026-12-03T12:00:00Z")
        );
        assert_eq!(
            limit(Side::Kernel, point, None).as_deref(),
            Some("2026-12-04T00:00:00Z")
        );
        assert_eq!(
            limit(Side::Kmod, point, released).as_deref(),
            Some("2026-12-04T00:00:00Z")
        );
        assert_eq!(
            limit(Side::Kmod, major, None).as_deref(),
            Some("2026-12-15T00:00:00Z")
        );
        assert_eq!(limit(Side::Kernel, driver, released), None);
        assert_eq!(limit(Side::Kmod, driver, None), None);
    }

    #[test]
    fn sides() {
        assert_eq!(
            Side::of_reason(b"kmod: nvidia-kmod-3:1-1.fc45.src does not build"),
            Side::Kmod
        );
        assert_eq!(
            Side::of_reason(b"kernel: rpmbuild -bb failed"),
            Side::Kernel
        );
        assert_eq!(
            Side::of_reason(b"check: a module has no signature"),
            Side::Kernel
        );
        assert_eq!(
            Side::of_reason(b"x.rpm does not have its pinned sha256"),
            Side::Kernel
        );
        assert_eq!(
            reason_of_stderr(b"log tail\nkmod: it failed\n\n"),
            b"kmod: it failed"
        );
    }

    #[test]
    fn lock_lines() {
        let t = Timer {
            limit: at("2026-12-04T00:00:00Z"),
            security: Security::Yes,
        };
        let line = held_line(
            ("K", false),
            b"2026-12-01T00:00:00Z",
            "kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src",
            Some(&t),
            Side::Kernel,
            b"kernel: x",
        );
        assert_eq!(
            text::lossy(&line),
            "held K since=2026-12-01T00:00:00Z limit=2026-12-04T00:00:00Z newer=kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src security=1 side=kernel reason=kernel: x"
        );
        assert_eq!(hold::good_key(&line).as_deref(), Some("K"));
        let line = held_line(("K", true), b"S", "n", None, Side::Kmod, b"kmod: y");
        assert_eq!(
            text::lossy(&line),
            "held K since=S newer=n degraded=nvidia side=kmod reason=kmod: y"
        );
        let line = degraded_line("D", b"S", "n", Some(&t), b"kmod: y");
        assert_eq!(
            text::lossy(&line),
            "built D since=S limit=2026-12-04T00:00:00Z newer=n security=1 degraded=nvidia side=kmod reason=kmod: y"
        );
        assert!(is_degraded(&line) && !is_degraded(b"built D"));
        assert_eq!(since(&line, "n", at("2026-12-09T00:00:00Z")), b"S");
        assert_eq!(
            since(&line, "m", at("2026-12-09T00:00:00Z")),
            b"2026-12-09T00:00:00Z"
        );
    }

    #[test]
    fn a_degraded_set_is_new_only_once() {
        let degraded = b"family kernel-cachyos built D since=S degraded=nvidia side=kmod reason=r\nfamily demo built K\n";
        let whole = b"family kernel-cachyos built K\nfamily demo built K\n";
        assert_eq!(newly_degraded(whole, degraded), ["kernel-cachyos"]);
        assert_eq!(newly_degraded(b"", degraded), ["kernel-cachyos"]);
        assert!(newly_degraded(degraded, degraded).is_empty());
        assert!(newly_degraded(degraded, whole).is_empty());
    }

    #[test]
    fn key_expiries() {
        let key = |expires: &str| PinnedKey {
            what: "the COPR key",
            fingerprint: "F".into(),
            expires: expires.into(),
        };
        let now = at("2026-12-01T12:00:00Z");
        assert_eq!(key_expiry(&key("2027-03-01"), now), KeyExpiry::Fine);
        assert_eq!(
            key_expiry(&key("2027-01-15"), now),
            KeyExpiry::Warn("the COPR key F expires on 2027-01-15, in 44 days".into())
        );
        assert_eq!(
            key_expiry(&key("2026-12-10"), now),
            KeyExpiry::Urgent(
                "the COPR key F expires on 2026-12-10, in 8 days: pin its successor now".into()
            )
        );
        assert!(
            matches!(key_expiry(&key("2026-12-01"), now), KeyExpiry::Expired(r) if r.starts_with("the COPR key F expired on 2026-12-01"))
        );
        assert_eq!(key_expiry(&key("not a date"), now), KeyExpiry::Fine);
    }

    #[test]
    fn module_counts() {
        let listing = b"/lib/modules/k/kernel/fs/erofs/erofs.ko.xz\n/usr/lib/modules/k/extra/nvidia/nvidia.ko.zst\n/lib/modules/k/vmlinuz\n/lib/modules/k/modules.dep\n/usr/share/doc/x.ko.txt\n/lib/modules/k/kernel/.ko\n";
        assert_eq!(count_modules(listing), 2);
        assert_eq!(module_drift(1000, 950, "K"), None, "5 % is within");
        assert_eq!(module_drift(1000, 1050, "K"), None);
        assert_eq!(
            module_drift(1000, 949, "K").as_deref(),
            Some("check: the pair has 949 modules, the last good pair K 1000: more than 5 % apart")
        );
        assert!(module_drift(1000, 1051, "K").is_some());
        assert_eq!(
            Side::of_reason(module_drift(10, 1, "K").unwrap().as_bytes()),
            Side::Kernel
        );
    }

    #[test]
    fn pair_locks() {
        let sha = "a".repeat(64);
        let text = format!(
            "kernel=kernel-cachyos-0:7.3.0-4.cachyos1.fc45.x86_64\nkmod=kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-3:615.78.08-1.fc45.x86_64\nmodule_cert_sha256={sha}\nrpm=kernel-cachyos-7.3.0-4.cachyos1.fc45.x86_64.rpm {sha}\n"
        );
        let lock = parse_pair_lock(text.as_bytes(), true).unwrap();
        assert_eq!(
            lock.kmod.unwrap().name,
            "kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64"
        );
        assert_eq!(lock.rpms.len(), 1);
        assert!(parse_pair_lock(text.as_bytes(), false).is_err());
        assert!(parse_pair_lock(format!("{text}kernel=x\n").as_bytes(), true).is_err());
        assert!(parse_pair_lock(format!("{text}rpm=../x.rpm {sha}\n").as_bytes(), true).is_err());
    }

    #[test]
    fn bump_reports() {
        let r = parse_bump(b"point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src\nnvidia nvidia-kmod-3:615.78.08-1.fc45.src abc pinned\nnvidia nvidia-driver-3:615.80.01-1.fc45.x86_64 abc newer\nnvidia nvidia-modprobe missing\n").unwrap();
        assert!(r.point.is_some_and(|n| n.version == "7.3.1") && r.major.is_none());
        assert_eq!(r.nvidia_newer, ["nvidia-driver-3:615.80.01-1.fc45.x86_64"]);
        assert_eq!(r.nvidia_missing, ["nvidia-modprobe"]);
        let r = parse_bump(
            b"major kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-12d\n",
        )
        .unwrap();
        assert!(
            r.point.is_none()
                && r.major
                    .is_some_and(|(n, eol)| n.version == "7.4.0" && eol == "12d")
        );
        let both = parse_bump(b"point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src\nmajor kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-unknown\nnvidia nvidia-modprobe missing\n").unwrap();
        assert!(both.point.is_some() && both.major.is_some_and(|(_, eol)| eol == "unknown"));
        let none = parse_bump(b"none\n").unwrap();
        assert!(none.point.is_none() && none.major.is_none());
        for bad in [
            &b"maybe\n"[..],
            b"none\nnvidia what\n",
            b"",
            b"nvidia nvidia-modprobe missing\n",
            b"major kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-1d\npoint kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src\n",
            b"none\nmajor kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-1d\n",
            b"point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src\nnvidia nvidia-modprobe missing\nmajor kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-1d\n",
        ] {
            assert!(parse_bump(bad).is_err(), "{}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn a_point_bump_moves_the_srpm_and_its_tag() {
        let new = Nevra::parse("kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src").unwrap();
        let out = bumped_kernel_env(
            format!("# c\n{KERNEL_ENV}").as_bytes(),
            &new,
            &"b".repeat(64),
        );
        let pins = parse_kernel("kernel.env", &out).unwrap();
        assert_eq!(pins.srpm, new);
        assert_eq!(pins.srpm_sha256, "b".repeat(64));
        assert_eq!(pins.tag.as_deref(), Some("cachyos-7.3.1-1"));
        assert!(out.starts_with(b"# c\ncopr="));
        assert!(is_point_of(&kernel("7.3.0-4"), &new));
        assert!(!is_point_of(&kernel("7.2.9-1"), &new));
    }

    #[test]
    fn apex_releases() {
        assert_eq!(apex_release("4.cachyos1.fc45", 1), "4.cachyos1.apex1.fc45");
        assert_eq!(apex_release("4.cachyos1", 3), "4.cachyos1.apex3");
        let nvr = "kernel-cachyos-7.3.0-4.cachyos1.fc45";
        assert_eq!(release_number(b"", nvr, "k1", false), Ok((1, true)));
        let ledger = format!("{nvr} k1 1\nkernel-cachyos-7.3.1-1.cachyos1.fc45 k9 5\n{nvr} k2 2\n");
        assert_eq!(
            release_number(ledger.as_bytes(), nvr, "k1", false),
            Ok((1, false))
        );
        assert_eq!(
            release_number(ledger.as_bytes(), nvr, "k2", false),
            Ok((2, false))
        );
        assert_eq!(
            release_number(ledger.as_bytes(), nvr, "k3", false),
            Ok((3, true)),
            "another NVR's N does not count"
        );
        assert!(release_number(b"a k1\n", nvr, "k1", false).is_err());
        assert!(release_number(b"a k1 0\n", nvr, "k1", false).is_err());
        assert_eq!(release_number(b"", nvr, "r1", true), Ok((9001, true)));
        let rehearsed = format!("{nvr} r1 9001\n");
        assert_eq!(
            release_number(rehearsed.as_bytes(), nvr, "r2", true),
            Ok((9002, true))
        );
        assert!(
            release_number(rehearsed.as_bytes(), nvr, "k2", false).is_err(),
            "the lane's store refuses N >= 9000"
        );
        assert!(
            release_number(ledger.as_bytes(), nvr, "k1", true).is_err(),
            "a rehearsal refuses N < 9000"
        );
        assert!(
            release_number(ledger.as_bytes(), nvr, "k7", true).is_ok(),
            "a new key in a rehearsal starts above the floor"
        );
    }
}
