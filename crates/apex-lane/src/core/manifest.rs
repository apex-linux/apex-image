//! `manifest.txt` of a stored set, format 1.

use crate::core::text;

pub const FORMAT_LINE: &str = "# apex-lane manifest 1: kind nevra sha256 file";

/// `sed -n 's/^# .* NAME=\([^ ]*\).*$/\1/p' | head -n 1`, which the stored manifests were
/// read with: the last ` NAME=` on the first `# ` line that has one.
pub fn header_field(manifest: &[u8], name: &str) -> Vec<u8> {
    let needle = format!(" {name}=");
    for line in text::lines(manifest) {
        let Some(rest) = line.strip_prefix(b"# ") else {
            continue;
        };
        let at = (0..rest.len())
            .rev()
            .find(|&i| rest[i..].starts_with(needle.as_bytes()));
        if let Some(at) = at {
            let value = &rest[at + needle.len()..];
            let end = value.iter().position(|&b| b == b' ').unwrap_or(value.len());
            return value[..end].to_vec();
        }
    }
    Vec::new()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry<'a> {
    pub kind: &'a [u8],
    pub nevra: &'a [u8],
    pub sha256: &'a [u8],
    pub file: &'a [u8],
}

/// The data lines (`grep -v '^#' | while read -r kind nevra sha file`).
pub fn entries(manifest: &[u8]) -> Vec<Entry<'_>> {
    text::lines(manifest)
        .into_iter()
        .filter(|line| !line.starts_with(b"#"))
        .map(|line| {
            let f = text::read_fields(line, 4);
            Entry {
                kind: f[0],
                nevra: f[1],
                sha256: f[2],
                file: f[3],
            }
        })
        .collect()
}

/// The kinds whose file is in the stored set.
pub fn is_stored_kind(kind: &[u8]) -> bool {
    matches!(kind, b"built" | b"mirror" | b"dev" | b"apex-srpm")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub pkg: String,
    pub family: String,
    pub key: String,
    pub release: String,
    pub n: u64,
    pub stock: String,
    pub pin_nvr: Option<String>,
    pub fedora: String,
    pub ga_reached: u8,
    pub base: String,
}

pub fn render_header(h: &Header) -> String {
    format!(
        "{FORMAT_LINE}\n# pkg={} family={} key={} release={} n={} stock={} pin={} fedora={} ga_reached={} base={}\n",
        h.pkg,
        h.family,
        h.key,
        h.release,
        h.n,
        h.stock,
        h.pin_nvr.as_deref().unwrap_or("-"),
        h.fedora,
        h.ga_reached,
        if h.base.is_empty() { "?" } else { &h.base },
    )
}

pub fn entry_line(kind: &str, nevra: &str, sha256: &str, file: &str) -> String {
    format!("{kind} {nevra} {sha256} {file}\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_field_rule() {
        let m = b"# apex-lane manifest 1: kind nevra sha256 file\n# pkg=x key=k1 release=r1 n=3 stock=s pin=-\n";
        assert_eq!(header_field(m, "key"), b"k1");
        assert_eq!(header_field(m, "release"), b"r1");
        assert_eq!(header_field(m, "pin"), b"-");
        assert_eq!(header_field(m, "nope"), b"");
        assert_eq!(
            header_field(b"# key=a\n# x key=b key=c\n", "key"),
            b"c",
            "the last on the first line that has it"
        );
        assert_eq!(header_field(b"#  key=a b\n", "key"), b"a");
        assert_eq!(
            header_field(b"# x key= y\n# x key=z\n", "key"),
            b"",
            "an empty value still counts"
        );
        assert_eq!(header_field(b"x key=a\n", "key"), b"");
    }

    #[test]
    fn data_lines() {
        let m = b"# h\nbuilt  a-0:1-1.x86_64 abc\tf g \n\n";
        let e = entries(m);
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].file, b"f g");
        assert_eq!(e[1].kind, b"");
    }
}
