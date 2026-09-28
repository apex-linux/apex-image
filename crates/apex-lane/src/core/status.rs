//! `status`: one block per family of a lock.

use crate::core::lock;
use crate::core::text;
use crate::core::utc::UtcSecond;

pub fn render(title: &str, lock_text: Option<&[u8]>, now: UtcSecond) -> Vec<u8> {
    let mut out = format!("{title}\n").into_bytes();
    let family_lines: Vec<&[u8]> = lock_text
        .map(text::lines)
        .unwrap_or_default()
        .into_iter()
        .filter(|line| line.starts_with(b"family "))
        .collect();
    let Some(lock_text) = lock_text.filter(|_| !family_lines.is_empty()) else {
        out.extend_from_slice(b"  (no family)\n");
        return out;
    };
    for line in family_lines {
        let f = text::read_fields(line, 5);
        let (name, state, key, rest) = (f[1], f[2], f[3], f[4]);
        out.extend_from_slice(b"  ");
        out.extend_from_slice(&pad(name, 22));
        out.push(b' ');
        out.extend_from_slice(&pad(state, 9));
        out.push(b' ');
        out.extend_from_slice(key);
        out.push(b'\n');
        if !rest.is_empty() {
            out.extend_from_slice(b"      ");
            out.extend_from_slice(rest);
            out.push(b'\n');
        }
        let limit = lock::attr(rest, "limit");
        if UtcSecond::parse(&limit).is_some_and(|limit| now >= limit) {
            out.extend_from_slice(
                b"      LIMIT REACHED: rebase the series, or ship Fedora's build (just pkg-stock)\n",
            );
        }
        let rpms = lock::rpm_lines(lock_text, &text::lossy(name));
        for rpm in text::lines(&rpms) {
            let f = text::fields(rpm);
            out.extend_from_slice(b"      ");
            out.extend_from_slice(&pad(f.get(2).copied().unwrap_or_default(), 7));
            out.push(b' ');
            out.extend_from_slice(f.get(4).copied().unwrap_or_default());
            out.push(b'\n');
        }
    }
    out
}

/// `printf '%-Ns'`.
fn pad(s: &[u8], width: usize) -> Vec<u8> {
    let mut out = s.to_vec();
    out.resize(width.max(s.len()), b' ');
    out
}
