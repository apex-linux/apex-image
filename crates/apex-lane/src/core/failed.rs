//! `failed.txt`: why the inputs gave no shippable build.

use crate::core::text;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure<'a> {
    pub reason: &'a [u8],
    pub pkg: &'a str,
    pub stock: Option<&'a str>,
    pub key: Option<&'a str>,
    /// The log's file name and its bytes.
    pub log: Option<(&'a str, &'a [u8])>,
}

pub fn failed_txt(f: &Failure<'_>) -> Vec<u8> {
    let mut out = f.reason.to_vec();
    out.extend_from_slice(
        format!(
            "\npkg={} stock={} key={}\n",
            f.pkg,
            f.stock.unwrap_or("?"),
            f.key.unwrap_or("?")
        )
        .as_bytes(),
    );
    if let Some((name, log)) = f.log {
        out.extend_from_slice(format!("\nlast 60 lines of {name}:\n").as_bytes());
        out.extend_from_slice(text::tail_lines(log, 60));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_and_without_a_log() {
        let mut f = Failure {
            reason: b"0002-loader.patch does not apply to gnome-shell-51.1-1.fc45",
            pkg: "gnome-shell",
            stock: Some("gnome-shell-51.1-1.fc45"),
            key: None,
            log: None,
        };
        assert_eq!(
            failed_txt(&f),
            b"0002-loader.patch does not apply to gnome-shell-51.1-1.fc45\npkg=gnome-shell stock=gnome-shell-51.1-1.fc45 key=?\n"
        );
        f.log = Some(("prep-apex.log", b"a\nb"));
        assert!(failed_txt(&f).ends_with(b"key=?\n\nlast 60 lines of prep-apex.log:\na\nb"));
    }
}
