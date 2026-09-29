//! `rpm-signing.env` names the Apex RPM key; it is read, never sourced.

use std::path::PathBuf;

use crate::core::text;
use crate::error::ConfigError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SigningEnv {
    /// Upper case, as gpg prints it.
    pub fingerprint: String,
    pub gnupg_home: PathBuf,
}

pub fn is_fingerprint(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

pub fn parse(file: &str, bytes: &[u8]) -> Result<SigningEnv, ConfigError> {
    let mut fingerprint = None;
    let mut gnupg_home = None;
    for (i, line) in text::lines(bytes).into_iter().enumerate() {
        let n = i + 1;
        if text::is_blank_or_comment(line) {
            continue;
        }
        let line = text::lossy(text::trim_end_space(line));
        let Some((key, value)) = line.split_once('=') else {
            return Err(ConfigError(format!("{file}:{n}: expected KEY=VALUE")));
        };
        let slot = match key {
            "APEX_RPM_KEY_FPR" => &mut fingerprint,
            "APEX_RPM_GNUPGHOME" => &mut gnupg_home,
            _ => return Err(ConfigError(format!("{file}:{n}: unknown key '{key}'"))),
        };
        if slot.replace(value.to_owned()).is_some() {
            return Err(ConfigError(format!("{file}:{n}: '{key}' is set twice")));
        }
    }
    let fingerprint = fingerprint
        .filter(|f| is_fingerprint(f))
        .ok_or_else(|| {
            ConfigError(format!(
                "{file}: APEX_RPM_KEY_FPR must be the key's fingerprint, 40 hex digits"
            ))
        })?
        .to_ascii_uppercase();
    let gnupg_home = gnupg_home.filter(|h| h.starts_with('/')).ok_or_else(|| {
        ConfigError(format!(
            "{file}: APEX_RPM_GNUPGHOME must be the absolute path of the GnuPG home that holds the key"
        ))
    })?;
    Ok(SigningEnv {
        fingerprint,
        gnupg_home: PathBuf::from(gnupg_home),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const FPR: &str = "553A938903DFFEEA647F7CC4ABEF111D1FCF882B";

    #[test]
    fn a_complete_file() {
        let env = parse(
            "e",
            format!(
                "# comment\n\nAPEX_RPM_KEY_FPR={}\nAPEX_RPM_GNUPGHOME=/home/b/.local/share/apex/rpm-gnupg \n",
                FPR.to_ascii_lowercase()
            )
            .as_bytes(),
        )
        .unwrap();
        assert_eq!(env.fingerprint, FPR);
        assert_eq!(
            env.gnupg_home,
            PathBuf::from("/home/b/.local/share/apex/rpm-gnupg")
        );
    }

    #[test]
    fn refusals() {
        let home = "APEX_RPM_GNUPGHOME=/g\n";
        let fpr = format!("APEX_RPM_KEY_FPR={FPR}\n");
        for (text, wanted) in [
            (
                format!("{fpr}{home}APEX_RPM_BACKEND=sq\n"),
                "e:3: unknown key 'APEX_RPM_BACKEND'",
            ),
            (
                format!("{fpr}{fpr}{home}"),
                "e:2: 'APEX_RPM_KEY_FPR' is set twice",
            ),
            (format!("{fpr}GNUPGHOME\n"), "e:2: expected KEY=VALUE"),
            (home.to_owned(), "e: APEX_RPM_KEY_FPR must be"),
            (
                format!("APEX_RPM_KEY_FPR={}\n{home}", &FPR[..16]),
                "e: APEX_RPM_KEY_FPR must be",
            ),
            (fpr.clone(), "e: APEX_RPM_GNUPGHOME must be"),
            (
                format!("{fpr}APEX_RPM_GNUPGHOME=~/g\n"),
                "e: APEX_RPM_GNUPGHOME must be",
            ),
        ] {
            let err = parse("e", text.as_bytes()).unwrap_err().0;
            assert!(err.starts_with(wanted), "{text:?}: {err}");
        }
    }
}
