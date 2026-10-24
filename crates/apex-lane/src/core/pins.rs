//! The pair's pins, apex-kernel's `kernel.env` and `nvidia.env`: read, never sourced.
//! pair.sh and bump.sh take each value whole with sed, so a stray space is refused here.

use std::collections::BTreeMap;
use std::fmt;

use crate::core::names::nevra_name;
use crate::core::text;
use crate::core::utc::UtcSecond;
use crate::error::ConfigError;

/// pair.sh builds `kernel-cachyos.spec` and finds `kernel-cachyos-[0-9]*.rpm`.
pub const KERNEL_NAME: &str = "kernel-cachyos";
pub const KMOD_SRPM_NAME: &str = "nvidia-kmod";

const KERNEL_KEYS: [&str; 11] = [
    "copr",
    "chroot",
    "srpm",
    "srpm_sha256",
    "copr_key",
    "copr_key_expires",
    "tag",
    "tag_repo",
    "tag_key",
    "tag_key_url",
    "tag_key_expires",
];
const KERNEL_REQUIRED: [&str; 5] = ["copr", "chroot", "srpm", "srpm_sha256", "copr_key"];
const NVIDIA_KEYS: [&str; 6] = [
    "kmod_srpm",
    "kmod_srpm_sha256",
    "userspace",
    "negativo17_key",
    "negativo17_key_expires",
    "soak_days",
];
const NVIDIA_REQUIRED: [&str; 3] = ["kmod_srpm", "kmod_srpm_sha256", "negativo17_key"];
/// bump.sh's soak when nvidia.env has no `soak_days`.
pub const DEFAULT_SOAK_DAYS: u32 = 7;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Nevra {
    pub name: String,
    pub epoch: String,
    pub version: String,
    pub release: String,
    pub arch: String,
}

impl Nevra {
    pub fn parse(s: &str) -> Option<Self> {
        let name = std::str::from_utf8(nevra_name(s.as_bytes())?).ok()?;
        let (epoch, rest) = s[name.len() + 1..].split_once(':')?;
        let (version, release_arch) = rest.split_once('-')?;
        let (release, arch) = release_arch.rsplit_once('.')?;
        let field = |f: &str| {
            !f.is_empty()
                && f.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"._+~^".contains(&c))
        };
        (field(version) && field(release) && field(arch)).then(|| Self {
            name: name.to_owned(),
            epoch: epoch.to_owned(),
            version: version.to_owned(),
            release: release.to_owned(),
            arch: arch.to_owned(),
        })
    }

    pub fn nvr(&self) -> String {
        format!("{}-{}-{}", self.name, self.version, self.release)
    }

    /// As rpmbuild names the file, and pair.sh's `file_of` finds it in the mirror.
    pub fn file_name(&self) -> String {
        format!("{}.{}.rpm", self.nvr(), self.arch)
    }
}

impl fmt::Display for Nevra {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}-{}:{}-{}.{}",
            self.name, self.epoch, self.version, self.release, self.arch
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelPins {
    pub copr: String,
    pub chroot: String,
    pub srpm: Nevra,
    pub srpm_sha256: String,
    pub copr_key: String,
    pub copr_key_expires: Option<String>,
    pub tag: Option<String>,
    pub tag_repo: Option<String>,
    pub tag_key: Option<String>,
    pub tag_key_url: Option<String>,
    pub tag_key_expires: Option<String>,
}

impl KernelPins {
    /// `7.3` of `7.3.0`: a new major is the owner's (ADR 0015), a point release is not.
    pub fn major(&self) -> String {
        major_of(&self.srpm.version)
    }

    /// kernel.org's `releases.json` names a `.0` release by its major alone.
    pub fn kernel_org_version(&self) -> String {
        let v = &self.srpm.version;
        match v.strip_suffix(".0") {
            Some(major) if major.matches('.').count() == 1 => major.to_owned(),
            _ => v.clone(),
        }
    }
}

pub fn major_of(version: &str) -> String {
    version.split('.').take(2).collect::<Vec<_>>().join(".")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NvidiaPins {
    pub kmod_srpm: Nevra,
    pub kmod_srpm_sha256: String,
    pub userspace: Vec<(Nevra, String)>,
    pub negativo17_key: String,
    pub negativo17_key_expires: Option<String>,
    /// Days a newer driver build must age before bump.sh calls it soaked.
    pub soak_days: u32,
}

fn is_sha256(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

fn is_fingerprint(s: &str) -> bool {
    s.len() == 40
        && s.bytes()
            .all(|c| c.is_ascii_digit() || (b'A'..=b'F').contains(&c))
}

/// bump.sh's `^[1-9][0-9]*$`, within u32.
fn is_days(s: &str) -> bool {
    !s.starts_with('0') && s.bytes().all(|c| c.is_ascii_digit()) && s.parse::<u32>().is_ok()
}

fn is_date(s: &str) -> bool {
    UtcSecond::parse(format!("{s}T00:00:00Z").as_bytes()).is_some()
}

fn is_https_url(s: &str) -> bool {
    s.len() > "https://".len()
        && s.starts_with("https://")
        && s.bytes()
            .all(|b| b.is_ascii_graphic() && !b"\"'`$\\".contains(&b))
}

fn is_word(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._+-".contains(&c))
}

fn is_copr(s: &str) -> bool {
    s.split_once('/').is_some_and(|(owner, project)| {
        is_word(owner.strip_prefix('@').unwrap_or(owner)) && is_word(project)
    })
}

/// Each key once, except `repeated`; values in order.
fn read_pins<'k>(
    file: &str,
    bytes: &[u8],
    keys: &[&'k str],
    repeated: &[&str],
) -> Result<BTreeMap<&'k str, Vec<String>>, ConfigError> {
    let mut out: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    for (i, line) in text::lines(bytes).into_iter().enumerate() {
        let n = i + 1;
        if text::is_blank_or_comment(line) {
            continue;
        }
        let line = String::from_utf8_lossy(line);
        let Some((key, value)) = line.split_once('=') else {
            return Err(ConfigError(format!("{file}:{n}: expected KEY=VALUE")));
        };
        let Some(known) = keys.iter().find(|k| **k == key) else {
            return Err(ConfigError(format!("{file}:{n}: unknown key '{key}'")));
        };
        if value.is_empty() || value.trim() != value || value.bytes().any(|c| c.is_ascii_control())
        {
            return Err(ConfigError(format!(
                "{file}:{n}: '{key}' has an empty value, a control character or a space at either end"
            )));
        }
        let values = out.entry(known).or_default();
        if !values.is_empty() && !repeated.contains(known) {
            return Err(ConfigError(format!("{file}:{n}: '{key}' is set twice")));
        }
        values.push(value.to_owned());
    }
    Ok(out)
}

struct Values<'f, 'k> {
    file: &'f str,
    map: BTreeMap<&'k str, Vec<String>>,
}

impl Values<'_, '_> {
    fn require(&self, required: &[&str]) -> Result<(), ConfigError> {
        match required.iter().find(|k| !self.map.contains_key(**k)) {
            Some(key) => Err(ConfigError(format!("{}: '{key}' is required", self.file))),
            None => Ok(()),
        }
    }

    fn opt(&self, key: &str) -> Option<String> {
        self.map.get(key).and_then(|v| v.first()).cloned()
    }

    fn get(&self, key: &str) -> String {
        self.opt(key).unwrap_or_default()
    }

    fn check(&self, key: &str, ok: fn(&str) -> bool, what: &str) -> Result<(), ConfigError> {
        match self.map.get(key).into_iter().flatten().find(|v| !ok(v)) {
            Some(bad) => Err(ConfigError(format!(
                "{}: {key} must be {what}, not '{bad}'",
                self.file
            ))),
            None => Ok(()),
        }
    }

    fn srpm(&self, key: &str, name: &str) -> Result<Nevra, ConfigError> {
        let value = self.get(key);
        Nevra::parse(&value)
            .filter(|n| n.name == name && n.arch == "src")
            .ok_or_else(|| {
                ConfigError(format!(
                    "{}: {key} must be the NEVRA of a {name} SRPM, like {name}-0:1.0-1.fc45.src, not '{value}'",
                    self.file
                ))
            })
    }
}

pub fn parse_kernel(file: &str, bytes: &[u8]) -> Result<KernelPins, ConfigError> {
    let v = Values {
        file,
        map: read_pins(file, bytes, &KERNEL_KEYS, &[])?,
    };
    v.require(&KERNEL_REQUIRED)?;
    v.check("copr", is_copr, "OWNER/PROJECT")?;
    v.check("chroot", is_word, "a COPR chroot name")?;
    v.check("srpm_sha256", is_sha256, "a lowercase sha256")?;
    v.check(
        "copr_key",
        is_fingerprint,
        "a 40-digit uppercase fingerprint",
    )?;
    v.check(
        "tag_key",
        is_fingerprint,
        "a 40-digit uppercase fingerprint",
    )?;
    v.check("tag", is_word, "a git tag name")?;
    for key in ["tag_repo", "tag_key_url"] {
        v.check(key, is_https_url, "an https:// URL")?;
    }
    for key in ["copr_key_expires", "tag_key_expires"] {
        v.check(key, is_date, "a date, YYYY-MM-DD")?;
    }
    let srpm = v.srpm("srpm", KERNEL_NAME)?;
    if srpm.version.split('.').count() != 3 {
        return Err(ConfigError(format!(
            "{file}: the kernel version {} is not MAJOR.MINOR.POINT",
            srpm.version
        )));
    }
    Ok(KernelPins {
        copr: v.get("copr"),
        chroot: v.get("chroot"),
        srpm,
        srpm_sha256: v.get("srpm_sha256"),
        copr_key: v.get("copr_key"),
        copr_key_expires: v.opt("copr_key_expires"),
        tag: v.opt("tag"),
        tag_repo: v.opt("tag_repo"),
        tag_key: v.opt("tag_key"),
        tag_key_url: v.opt("tag_key_url"),
        tag_key_expires: v.opt("tag_key_expires"),
    })
}

/// apex-kernel's pins as the lane reads them: both files parse, and the tag pins that
/// `kernel-bump` needs are set.
pub fn check_pins(kernel: &[u8], nvidia: &[u8]) -> Result<(KernelPins, NvidiaPins), ConfigError> {
    let k = parse_kernel("kernel.env", kernel)?;
    let n = parse_nvidia("nvidia.env", nvidia)?;
    for (key, value) in [
        ("tag", &k.tag),
        ("tag_repo", &k.tag_repo),
        ("tag_key", &k.tag_key),
        ("tag_key_url", &k.tag_key_url),
    ] {
        if value.is_none() {
            return Err(ConfigError(format!(
                "kernel.env: '{key}' is required: kernel-bump verifies the CachyOS tag with it"
            )));
        }
    }
    Ok((k, n))
}

pub fn parse_nvidia(file: &str, bytes: &[u8]) -> Result<NvidiaPins, ConfigError> {
    let v = Values {
        file,
        map: read_pins(file, bytes, &NVIDIA_KEYS, &["userspace"])?,
    };
    v.require(&NVIDIA_REQUIRED)?;
    v.check("kmod_srpm_sha256", is_sha256, "a lowercase sha256")?;
    v.check(
        "negativo17_key",
        is_fingerprint,
        "a 40-digit uppercase fingerprint",
    )?;
    v.check("negativo17_key_expires", is_date, "a date, YYYY-MM-DD")?;
    v.check("soak_days", is_days, "a whole number of days, 1 or more")?;
    let mut userspace: Vec<(Nevra, String)> = Vec::new();
    for line in v.map.get("userspace").into_iter().flatten() {
        let parsed = line.split_once(' ').and_then(|(nevra, sha)| {
            Nevra::parse(nevra)
                .filter(|n| n.arch == "x86_64" || n.arch == "noarch")
                .zip(is_sha256(sha).then(|| sha.to_owned()))
        });
        let Some((nevra, sha)) = parsed else {
            return Err(ConfigError(format!(
                "{file}: a userspace line is 'NEVRA SHA256' of an x86_64 or noarch RPM, not '{line}'"
            )));
        };
        if userspace.iter().any(|(n, _)| n.name == nevra.name) {
            return Err(ConfigError(format!(
                "{file}: userspace pins {} twice",
                nevra.name
            )));
        }
        userspace.push((nevra, sha));
    }
    Ok(NvidiaPins {
        kmod_srpm: v.srpm("kmod_srpm", KMOD_SRPM_NAME)?,
        kmod_srpm_sha256: v.get("kmod_srpm_sha256"),
        userspace,
        negativo17_key: v.get("negativo17_key"),
        negativo17_key_expires: v.opt("negativo17_key_expires"),
        soak_days: v
            .opt("soak_days")
            .and_then(|d| d.parse().ok())
            .unwrap_or(DEFAULT_SOAK_DAYS),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const KERNEL_ENV: &str = concat!(
        "# pins\n",
        "\n",
        "copr=bieszczaders/kernel-cachyos\n",
        "chroot=fedora-45-x86_64\n",
        "srpm=kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src\n",
        "srpm_sha256=e6b57189499ce41b78255deadc86f38e318e24e895283b7e1f412a23de9cf49f\n",
        "copr_key=537DEED33436B0367F5B26D5B3E3132CF10859CF\n",
        "copr_key_expires=2028-01-23\n",
        "\n",
        "tag=cachyos-7.3.0-4\n",
        "tag_repo=https://github.com/CachyOS/linux.git\n",
        "tag_key=E8B9AA39F054E30E8290D492C3C4820857F654FE\n",
        "tag_key_url=https://keys.openpgp.org/vks/v1/by-fingerprint/E8B9AA39F054E30E8290D492C3C4820857F654FE\n",
        "tag_key_expires=2028-03-31\n",
    );
    const NVIDIA_ENV: &str = concat!(
        "kmod_srpm=nvidia-kmod-3:615.78.08-1.fc45.src\n",
        "kmod_srpm_sha256=2a16e83c24605b0f3c436caacb133c7b1b7724b105ed7c970ddf1a6809668532\n",
        "\n",
        "userspace=nvidia-driver-3:615.78.08-1.fc45.x86_64 2099da1e492b1abf2651c49b1a98f27ca215517bdddad06438769d0e25d2a6e4\n",
        "userspace=nvidia-driver-selinux-0:0.1-3.fc45.noarch 338924e031cf136ca842d2f1b4d7c53aec24b1c1072147ac90a44667f89d73c4\n",
        "negativo17_key=0C5D0F470484AE2FC40A9B6597F3008993E8909B\n",
        "negativo17_key_expires=2029-08-31\n",
    );

    #[test]
    fn the_pins_of_apex_kernel() {
        let k = parse_kernel("kernel.env", KERNEL_ENV.as_bytes()).unwrap();
        assert_eq!(
            k.srpm.to_string(),
            "kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src"
        );
        assert_eq!(
            k.srpm.file_name(),
            "kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm"
        );
        assert_eq!(k.srpm.nvr(), "kernel-cachyos-7.3.0-4.cachyos1.fc45");
        assert_eq!(
            (k.major().as_str(), k.kernel_org_version().as_str()),
            ("7.3", "7.3")
        );
        assert_eq!(k.tag.as_deref(), Some("cachyos-7.3.0-4"));
        assert_eq!(
            k.tag_repo.as_deref(),
            Some("https://github.com/CachyOS/linux.git")
        );
        assert!(
            k.tag_key_url
                .unwrap()
                .ends_with("/E8B9AA39F054E30E8290D492C3C4820857F654FE")
        );
        let n = parse_nvidia("nvidia.env", NVIDIA_ENV.as_bytes()).unwrap();
        assert_eq!(
            n.kmod_srpm.file_name(),
            "nvidia-kmod-615.78.08-1.fc45.src.rpm"
        );
        assert_eq!(n.userspace.len(), 2);
        assert_eq!(
            n.userspace[1].0.file_name(),
            "nvidia-driver-selinux-0.1-3.fc45.noarch.rpm"
        );
    }

    #[test]
    fn point_releases() {
        let text = KERNEL_ENV.replace("7.3.0-4", "7.3.2-1");
        let k = parse_kernel("kernel.env", text.as_bytes()).unwrap();
        assert_eq!(
            (k.major().as_str(), k.kernel_org_version().as_str()),
            ("7.3", "7.3.2")
        );
    }

    #[test]
    fn check_pins_wants_the_tag_pins() {
        let (k, n) = check_pins(KERNEL_ENV.as_bytes(), NVIDIA_ENV.as_bytes()).unwrap();
        assert_eq!(k.srpm.nvr(), "kernel-cachyos-7.3.0-4.cachyos1.fc45");
        assert_eq!(
            n.kmod_srpm.to_string(),
            "nvidia-kmod-3:615.78.08-1.fc45.src"
        );
        let check = |kernel: String| {
            check_pins(kernel.as_bytes(), NVIDIA_ENV.as_bytes())
                .unwrap_err()
                .0
        };
        assert_eq!(
            check(KERNEL_ENV.replace("tag_repo=https://github.com/CachyOS/linux.git\n", "")),
            "kernel.env: 'tag_repo' is required: kernel-bump verifies the CachyOS tag with it"
        );
        assert!(
            check(KERNEL_ENV.replace("tag_key_url=https://", "tag_key_url=http://"))
                .contains("tag_key_url must be an https:// URL")
        );
        let bad_nvidia = check_pins(KERNEL_ENV.as_bytes(), b"kmod_srpm=x\n")
            .unwrap_err()
            .0;
        assert!(bad_nvidia.starts_with("nvidia.env: "), "{bad_nvidia}");
    }

    fn kernel_error(text: &str) -> String {
        parse_kernel("kernel.env", text.as_bytes()).unwrap_err().0
    }

    #[test]
    fn kernel_env_is_strict() {
        for (text, says) in [
            (KERNEL_ENV.replace("copr=", "#copr="), "'copr' is required"),
            (format!("{KERNEL_ENV}copr=a/b\n"), "'copr' is set twice"),
            (format!("{KERNEL_ENV}kernel=x\n"), "unknown key 'kernel'"),
            (format!("{KERNEL_ENV}just text\n"), "expected KEY=VALUE"),
            (
                KERNEL_ENV.replace("chroot=fedora-45-x86_64", "chroot=fedora-45-x86_64 "),
                "a space at either end",
            ),
            (
                KERNEL_ENV.replace("srpm_sha256=e6", "srpm_sha256=E6"),
                "srpm_sha256 must be a lowercase sha256",
            ),
            (
                KERNEL_ENV.replace("copr_key=537D", "copr_key=537d"),
                "copr_key must be a 40-digit",
            ),
            (
                KERNEL_ENV.replace("2028-01-23", "2028-02-30"),
                "copr_key_expires must be a date",
            ),
            (
                KERNEL_ENV.replace("tag_repo=https://", "tag_repo=http://"),
                "tag_repo must be an https:// URL",
            ),
            (
                KERNEL_ENV.replace("tag_key_url=https://keys", "tag_key_url=https://$keys"),
                "tag_key_url must be an https:// URL",
            ),
            (
                KERNEL_ENV.replace("copr=bieszczaders/", "copr=bieszczaders "),
                "copr must be OWNER/PROJECT",
            ),
            (
                KERNEL_ENV.replace("srpm=kernel-cachyos-0:", "srpm=kernel-0:"),
                "the NEVRA of a kernel-cachyos SRPM",
            ),
            (
                KERNEL_ENV.replace(".fc45.src\n", ".fc45.x86_64\n"),
                "the NEVRA of a kernel-cachyos SRPM",
            ),
            (
                KERNEL_ENV.replace("0:7.3.0-4", "7.3.0-4"),
                "the NEVRA of a kernel-cachyos SRPM",
            ),
            (
                KERNEL_ENV.replace("0:7.3.0-4", "0:7.3-4"),
                "not MAJOR.MINOR.POINT",
            ),
        ] {
            let err = kernel_error(&text);
            assert!(err.contains(says), "{says}: {err}");
        }
        assert!(parse_kernel("k", b"copr=@group/p\nchroot=c\nsrpm=kernel-cachyos-0:1.2.3-1.fc45.src\nsrpm_sha256=e6b57189499ce41b78255deadc86f38e318e24e895283b7e1f412a23de9cf49f\ncopr_key=537DEED33436B0367F5B26D5B3E3132CF10859CF").is_ok());
    }

    #[test]
    fn nvidia_env_is_strict() {
        let error = |text: &str| parse_nvidia("nvidia.env", text.as_bytes()).unwrap_err().0;
        for (text, says) in [
            (
                NVIDIA_ENV.replace("negativo17_key=", "#"),
                "'negativo17_key' is required",
            ),
            (
                format!("{NVIDIA_ENV}kmod_srpm=nvidia-kmod-3:1-1.fc45.src\n"),
                "'kmod_srpm' is set twice",
            ),
            (
                NVIDIA_ENV.replace("nvidia-kmod-3:", "nvidia-kmod-common-3:"),
                "a nvidia-kmod SRPM",
            ),
            (
                NVIDIA_ENV.replace(".fc45.x86_64 2099", ".fc45.i686 2099"),
                "x86_64 or noarch",
            ),
            (
                NVIDIA_ENV.replace(".noarch 3389", ".noarch  3389"),
                "x86_64 or noarch",
            ),
            (NVIDIA_ENV.replace(" 2099da1e", " 2099"), "x86_64 or noarch"),
            (
                NVIDIA_ENV.replace("nvidia-driver-selinux-0", "nvidia-driver-0"),
                "pins nvidia-driver twice",
            ),
        ] {
            let err = error(&text);
            assert!(err.contains(says), "{says}: {err}");
        }
    }

    #[test]
    fn nevras() {
        let n = Nevra::parse("kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-3:615.78.08-1.fc45.x86_64")
            .unwrap();
        assert_eq!(n.name, "kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64");
        assert_eq!(
            n.file_name(),
            "kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-615.78.08-1.fc45.x86_64.rpm"
        );
        assert_eq!(Nevra::parse("x-0:1-1.fc45.src x"), None);
        assert_eq!(Nevra::parse("x-1-1.fc45.src"), None);
    }

    #[test]
    fn soak_days_is_optional_whole_days() {
        let soak =
            |extra: &str| parse_nvidia("nvidia.env", format!("{NVIDIA_ENV}{extra}").as_bytes());
        assert_eq!(soak("").unwrap().soak_days, DEFAULT_SOAK_DAYS);
        assert_eq!(soak("soak_days=10\n").unwrap().soak_days, 10);
        for bad in ["0", "07", "-1", "7d", "1.5", "99999999999"] {
            let err = soak(&format!("soak_days={bad}\n")).unwrap_err().0;
            assert!(
                err.contains("soak_days must be a whole number of days"),
                "{bad}: {err}"
            );
        }
        let err = soak("soak_days=7\nsoak_days=8\n").unwrap_err().0;
        assert!(err.contains("'soak_days' is set twice"), "{err}");
    }
}
