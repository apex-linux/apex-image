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
            out.extend_from_slice(match &lock::attr(rest, "side")[..] {
                b"kernel" => b"      LIMIT REACHED: the owner chooses: wait for a pair that builds, or the break-glass image\n".as_slice(),
                b"kmod" => b"      LIMIT REACHED: the new kernel ships with degraded=nvidia, with the owner's publish override\n",
                _ => b"      LIMIT REACHED: rebase the series, or ship Fedora's build (just pkg-stock)\n",
            });
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

fn pad(s: &[u8], width: usize) -> Vec<u8> {
    let mut out = s.to_vec();
    out.resize(width.max(s.len()), b' ');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pair_at_its_limit_names_the_owners_choice() {
        let now = UtcSecond::parse(b"2026-12-10T00:00:00Z").unwrap_or(UtcSecond(0));
        let lock = |side: &str| {
            format!(
                "family kernel-cachyos held K since=2026-12-01T00:00:00Z limit=2026-12-04T00:00:00Z side={side} reason=x\n"
            )
        };
        let shown = |side: &str| text::lossy(&render("t", Some(lock(side).as_bytes()), now));
        assert!(shown("kernel").contains("break-glass image"));
        assert!(shown("kmod").contains("degraded=nvidia"));
        assert!(shown("").contains("just pkg-stock"));
    }
}
