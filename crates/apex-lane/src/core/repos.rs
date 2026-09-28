use std::collections::BTreeSet;

use crate::core::text;

pub const SETOPTS: [&str; 1] = ["--setopt=install_weak_deps=False"];

pub fn containerfile_arg(containerfile: &[u8], name: &str) -> String {
    for line in text::lines(containerfile) {
        let rest = text::trim_start_space(line);
        let Some(rest) = rest.strip_prefix(b"ARG") else {
            continue;
        };
        let spaces = rest.iter().take_while(|&&b| text::is_space(b)).count();
        if spaces == 0 {
            continue;
        }
        let Some(value) = rest[spaces..]
            .strip_prefix(name.as_bytes())
            .and_then(|r| r.strip_prefix(b"="))
        else {
            continue;
        };
        let mut v = text::trim_end_space(value);
        for quote in *b"\"'" {
            if v.len() >= 2 && v[0] == quote && v[v.len() - 1] == quote {
                v = &v[1..v.len() - 1];
            }
        }
        return text::lossy(v);
    }
    String::new()
}

pub fn is_fedora_pin(s: &str) -> bool {
    let Some(rest) = s.strip_prefix("registry.fedoraproject.org/") else {
        return false;
    };
    let Some((name_tag, digest)) = rest.split_once("@sha256:") else {
        return false;
    };
    let (name, tag) = match name_tag.split_once(':') {
        Some((n, t)) => (n, Some(t)),
        None => (name_tag, None),
    };
    let ok = |s: &str, extra: &[u8], upper: bool| {
        !s.is_empty()
            && s.bytes().all(|c| {
                c.is_ascii_lowercase()
                    || c.is_ascii_digit()
                    || (upper && c.is_ascii_uppercase())
                    || extra.contains(&c)
            })
    };
    ok(name, b"._-", false)
        && tag.is_none_or(|t| ok(t, b"._-", true))
        && digest.len() == 64
        && digest
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

pub fn ga_reached(env: Option<&str>, containerfile_value: &str) -> Result<u8, String> {
    let v = env.filter(|v| !v.is_empty()).unwrap_or(containerfile_value);
    match v {
        "" | "0" => Ok(0),
        "1" => Ok(1),
        other => Err(format!("GA_REACHED must be 0 or 1, got '{other}'")),
    }
}

pub fn testing_includepkgs(allowlist: Option<&[u8]>) -> String {
    let entries: Vec<String> = allowlist
        .map(text::lines)
        .unwrap_or_default()
        .into_iter()
        .map(|line| {
            text::strip_comment(line)
                .iter()
                .copied()
                .filter(|&b| !text::is_space(b))
                .collect::<Vec<u8>>()
        })
        .filter(|e| !e.is_empty())
        .map(|e| text::lossy(&e))
        .collect();
    entries.join(",")
}

/// Every subpackage of the allowlisted builds, so the buildroot also gets the -devel
/// packages the runtime allowlist leaves out. `builds`: one source RPM per line; `all`:
/// `NVR SOURCERPM` lines.
pub fn admitted(builds: &[u8], all: &[u8]) -> String {
    let wanted: BTreeSet<&[u8]> = text::lines(builds)
        .into_iter()
        .map(|l| text::fields(l).first().copied().unwrap_or_default())
        .collect();
    let names: BTreeSet<&[u8]> = text::lines(all)
        .into_iter()
        .filter_map(|l| {
            let f = text::fields(l);
            let first = f.first().copied().unwrap_or_default();
            let source = f.get(1).copied().unwrap_or_default();
            wanted.contains(source).then_some(first)
        })
        .collect();
    names
        .into_iter()
        .map(text::lossy)
        .collect::<Vec<_>>()
        .join(",")
}

pub fn sort_unique(lines: &[u8]) -> Vec<u8> {
    let set: BTreeSet<&[u8]> = text::lines(lines).into_iter().collect();
    text::join_lines(&set.into_iter().collect::<Vec<_>>())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Repos {
    pub bin: Vec<String>,
    pub src: Vec<String>,
}

impl Repos {
    pub fn released() -> Self {
        Self {
            bin: vec!["--repo=fedora".into(), "--repo=updates".into()],
            src: vec![
                "--repo=fedora-source".into(),
                "--repo=updates-source".into(),
            ],
        }
    }

    #[must_use]
    pub fn with_testing(mut self, admitted: &str) -> Self {
        self.bin.push("--repo=updates-testing".into());
        self.bin
            .push(format!("--setopt=updates-testing.includepkgs={admitted}"));
        self.src.push("--repo=updates-testing-source".into());
        self
    }

    pub fn key_text(&self) -> String {
        format!("{} {}", self.bin.join(" "), SETOPTS.join(" "))
    }
}

pub fn refresh_repos(testing: bool) -> Vec<String> {
    let mut out: Vec<String> = [
        "--repo=fedora",
        "--repo=updates",
        "--repo=fedora-source",
        "--repo=updates-source",
    ]
    .map(String::from)
    .to_vec();
    if testing {
        out.push("--repo=updates-testing".into());
        out.push("--repo=updates-testing-source".into());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn containerfile_args() {
        let cf = b"FROM x\n  ARG  REPOS_BASE=\"registry.fedoraproject.org/fedora@sha256:ab\"  \nARG REPOS_BASE=later\nARG GA_REACHED='0'\nARGX GA=1\n";
        assert_eq!(
            containerfile_arg(cf, "REPOS_BASE"),
            "registry.fedoraproject.org/fedora@sha256:ab"
        );
        assert_eq!(containerfile_arg(cf, "GA_REACHED"), "0");
        assert_eq!(containerfile_arg(cf, "GA"), "");
        assert_eq!(containerfile_arg(b"ARG X=\"'y'\"\n", "X"), "y");
    }

    #[test]
    fn pins() {
        let d = "1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb";
        assert!(is_fedora_pin(&format!(
            "registry.fedoraproject.org/fedora@sha256:{d}"
        )));
        assert!(is_fedora_pin(&format!(
            "registry.fedoraproject.org/fedora:45@sha256:{d}"
        )));
        assert!(!is_fedora_pin(&format!("quay.io/fedora/fedora@sha256:{d}")));
        assert!(!is_fedora_pin("registry.fedoraproject.org/fedora:45"));
        assert!(!is_fedora_pin(&format!(
            "registry.fedoraproject.org/fedora@sha256:{}",
            &d[1..]
        )));
    }

    #[test]
    fn ga_switch() {
        assert_eq!(ga_reached(None, "0"), Ok(0));
        assert_eq!(ga_reached(Some("1"), "0"), Ok(1));
        assert_eq!(ga_reached(Some(""), ""), Ok(0));
        assert!(ga_reached(Some("yes"), "0").is_err());
    }

    #[test]
    fn admission() {
        assert_eq!(
            testing_includepkgs(Some(b"# c\n mutter \n\ngtk4 # x\n")),
            "mutter,gtk4"
        );
        assert_eq!(testing_includepkgs(None), "");
        let builds = b"mutter-51.0-1.fc45.src.rpm\n";
        let all = b"mutter-devel-51.0-1.fc45 mutter-51.0-1.fc45.src.rpm\nmutter-51.0-1.fc45 mutter-51.0-1.fc45.src.rpm\ngtk4-4.24-1.fc45 gtk4-4.24-1.fc45.src.rpm\n";
        assert_eq!(
            admitted(builds, all),
            "mutter-51.0-1.fc45,mutter-devel-51.0-1.fc45"
        );
        assert_eq!(
            Repos::released().with_testing("a,b").key_text(),
            "--repo=fedora --repo=updates --repo=updates-testing --setopt=updates-testing.includepkgs=a,b --setopt=install_weak_deps=False"
        );
    }
}
