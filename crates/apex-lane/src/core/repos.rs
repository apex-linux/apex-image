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

    pub fn key_text(&self) -> String {
        format!("{} {}", self.bin.join(" "), SETOPTS.join(" "))
    }
}

pub fn refresh_repos() -> Vec<String> {
    let r = Repos::released();
    r.bin.into_iter().chain(r.src).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn containerfile_args() {
        let cf = b"FROM x\n  ARG  REPOS_BASE=\"registry.fedoraproject.org/fedora@sha256:ab\"  \nARG REPOS_BASE=later\nARG RELEASE_BUILD='0'\nARGX GA=1\n";
        assert_eq!(
            containerfile_arg(cf, "REPOS_BASE"),
            "registry.fedoraproject.org/fedora@sha256:ab"
        );
        assert_eq!(containerfile_arg(cf, "RELEASE_BUILD"), "0");
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
    fn released_repositories() {
        assert_eq!(
            Repos::released().key_text(),
            "--repo=fedora --repo=updates --setopt=install_weak_deps=False"
        );
        assert_eq!(
            refresh_repos(),
            [
                "--repo=fedora",
                "--repo=updates",
                "--repo=fedora-source",
                "--repo=updates-source"
            ]
        );
    }
}
