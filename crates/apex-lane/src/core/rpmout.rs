use crate::core::text;

pub const STOCK_FORMAT: &str = "%{name} %{epoch} %{version} %{release} %{sourcerpm}\\n";
pub const PIN_FORMAT: &str = "%{epoch} %{version} %{release} %{sourcerpm}\\n";
pub const MIRROR_FORMAT: &str =
    "%{name}-%{epoch}:%{version}-%{release}.%{arch} %{evr} %{sourcerpm}\\n";

pub fn one_line(output: &[u8]) -> Option<&[u8]> {
    let out = text::chomp(output);
    (!out.is_empty() && !out.contains(&b'\n')).then_some(out)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub epoch: String,
    pub version: String,
    pub release: String,
    pub sourcerpm: String,
}

/// A line of [`STOCK_FORMAT`].
pub fn stock_line(line: &[u8]) -> Resolved {
    let f = text::read_fields(line, 5);
    Resolved {
        epoch: text::lossy(f[1]),
        version: text::lossy(f[2]),
        release: text::lossy(f[3]),
        sourcerpm: text::lossy(f[4]),
    }
}

/// A line of [`PIN_FORMAT`].
pub fn pin_line(line: &[u8]) -> Resolved {
    let f = text::read_fields(line, 4);
    Resolved {
        epoch: text::lossy(f[0]),
        version: text::lossy(f[1]),
        release: text::lossy(f[2]),
        sourcerpm: text::lossy(f[3]),
    }
}

/// The NEVRAs of the [`MIRROR_FORMAT`] lines at `evr` built from `sourcerpm`.
pub fn mirror_nevras(output: &[u8], evr: &str, sourcerpm: &str) -> Vec<u8> {
    let hits: Vec<&[u8]> = text::lines(output)
        .into_iter()
        .map(text::fields)
        .filter(|f| {
            f.get(1).copied().unwrap_or_default() == evr.as_bytes()
                && f.get(2).copied().unwrap_or_default() == sourcerpm.as_bytes()
        })
        .map(|f| f.first().copied().unwrap_or_default())
        .collect();
    text::join_lines(&hits)
}

/// dnf names a downloaded NEVRA without its epoch.
pub fn nevra_file_stem(nevra: &str) -> String {
    let b = nevra.as_bytes();
    for i in 0..b.len() {
        if b[i] == b'-' {
            let digits = b[i + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
            if digits > 0 && b.get(i + 1 + digits) == Some(&b':') {
                return format!("{}-{}", &nevra[..i], &nevra[i + 2 + digits..]);
            }
        }
    }
    nevra.to_owned()
}

pub fn download_spec(nevra: &str) -> String {
    nevra.replacen("-0:", "-", 1)
}

/// From `gpg --with-colons` output.
pub fn first_fingerprint(output: &[u8]) -> String {
    const FINGERPRINT_FIELD: usize = 9;
    text::lines(output)
        .into_iter()
        .map(|l| l.split(|&b| b == b':').collect::<Vec<_>>())
        .find(|f| f.first() == Some(&&b"fpr"[..]))
        .map(|f| text::lossy(f.get(FINGERPRINT_FIELD).copied().unwrap_or_default()))
        .unwrap_or_default()
}

/// From `gpg --with-colons` output: one per primary key, never a subkey's.
pub fn primary_fingerprints(output: &[u8]) -> Vec<String> {
    const FINGERPRINT_FIELD: usize = 9;
    let mut out = Vec::new();
    let mut after_pub = false;
    for line in text::lines(output) {
        let f: Vec<&[u8]> = line.split(|&b| b == b':').collect();
        match f[0] {
            b"pub" => after_pub = true,
            b"fpr" if after_pub => {
                out.push(text::lossy(
                    f.get(FINGERPRINT_FIELD).copied().unwrap_or_default(),
                ));
                after_pub = false;
            }
            b"sub" | b"sec" | b"ssb" => after_pub = false,
            _ => {}
        }
    }
    out
}

pub fn has_line(output: &[u8], line: &str) -> bool {
    text::lines(output)
        .into_iter()
        .any(|l| l == line.as_bytes())
}

pub fn check_reason(log: &[u8]) -> Vec<u8> {
    text::lines(log)
        .into_iter()
        .rfind(|l| !l.starts_with(b"ok "))
        .map(<[u8]>::to_vec)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readings() {
        assert_eq!(one_line(b"a b\n"), Some(&b"a b"[..]));
        assert_eq!(one_line(b"a\nb\n"), None);
        assert_eq!(one_line(b"\n"), None);
        assert_eq!(
            nevra_file_stem("mutter-0:51.0-1.fc45.x86_64"),
            "mutter-51.0-1.fc45.x86_64"
        );
        assert_eq!(nevra_file_stem("a-b-12:1-1.x"), "a-b-1-1.x");
        assert_eq!(
            download_spec("mutter-0:51.0-1.fc45.x86_64"),
            "mutter-51.0-1.fc45.x86_64"
        );
        assert_eq!(
            first_fingerprint(b"pub:-:4096:1:655A4B02F577861E:1:::::scESC::::::23::0:\nfpr:::::::::4F50A6114CD5C6976A7F1179655A4B02F577861E:\n"),
            "4F50A6114CD5C6976A7F1179655A4B02F577861E"
        );
        assert_eq!(
            primary_fingerprints(b"pub:-:255:22:ABEF111D1FCF882B:1::::scSC:\nfpr:::::::::553A938903DFFEEA647F7CC4ABEF111D1FCF882B:\nuid:-::::1::X::A::\nsub:-:255:18:1:1::::e:\nfpr:::::::::0000000000000000000000000000000000000001:\npub:-:255:22:2:1::::scSC:\nfpr:::::::::0000000000000000000000000000000000000002:\n"),
            [
                "553A938903DFFEEA647F7CC4ABEF111D1FCF882B",
                "0000000000000000000000000000000000000002"
            ]
        );
        assert_eq!(check_reason(b"ok a\nnot ok: b\nok c\n"), b"not ok: b");
        assert_eq!(
            mirror_nevras(b"mutter-0:51.0-1.fc45.x86_64 51.0-1.fc45 mutter-51.0-1.fc45.src.rpm\nmutter-0:50-1.fc45.x86_64 50-1.fc45 mutter-50-1.fc45.src.rpm\n", "51.0-1.fc45", "mutter-51.0-1.fc45.src.rpm"),
            b"mutter-0:51.0-1.fc45.x86_64\n"
        );
    }
}
