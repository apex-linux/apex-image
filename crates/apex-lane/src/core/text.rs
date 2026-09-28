//! Line and field rules of the tools the lane's formats were first written with: awk,
//! grep, `read -r` and `$(...)`, in the C locale.

/// `[[:space:]]` in the C locale.
pub fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')
}

/// The default field separators of awk and of `read` (space, tab, newline).
pub fn is_blank(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n')
}

/// Lines as awk, grep and `while read || [[ -n $line ]]` see them: a final line without a
/// newline counts.
pub fn lines(text: &[u8]) -> Vec<&[u8]> {
    if text.is_empty() {
        return Vec::new();
    }
    let body = text.strip_suffix(b"\n").unwrap_or(text);
    body.split(|&b| b == b'\n').collect()
}

/// Lines as a plain `while read` loop sees them: a final line without a newline is lost.
pub fn complete_lines(text: &[u8]) -> Vec<&[u8]> {
    let mut all = lines(text);
    if !text.is_empty() && !text.ends_with(b"\n") {
        all.pop();
    }
    all
}

pub fn trim_end_space(s: &[u8]) -> &[u8] {
    let end = s.iter().rposition(|&b| !is_space(b)).map_or(0, |i| i + 1);
    &s[..end]
}

pub fn trim_start_space(s: &[u8]) -> &[u8] {
    let start = s.iter().position(|&b| !is_space(b)).unwrap_or(s.len());
    &s[start..]
}

fn trim_blank(s: &[u8]) -> &[u8] {
    let start = s.iter().position(|&b| !is_blank(b)).unwrap_or(s.len());
    let s = &s[start..];
    let end = s.iter().rposition(|&b| !is_blank(b)).map_or(0, |i| i + 1);
    &s[..end]
}

/// awk's default fields.
pub fn fields(line: &[u8]) -> Vec<&[u8]> {
    line.split(|&b| is_blank(b))
        .filter(|f| !f.is_empty())
        .collect()
}

/// `read -r v1 ... vN`: N values, the last one holding the rest of the line.
pub fn read_fields(line: &[u8], n: usize) -> Vec<&[u8]> {
    let mut out = Vec::with_capacity(n);
    let mut rest = trim_blank(line);
    while out.len() + 1 < n {
        let end = rest.iter().position(|&b| is_blank(b)).unwrap_or(rest.len());
        out.push(&rest[..end]);
        rest = trim_blank(&rest[end..]);
    }
    if n > 0 {
        out.push(rest);
    }
    out
}

/// `$(...)`: trailing newlines removed.
pub fn chomp(s: &[u8]) -> &[u8] {
    let end = s.iter().rposition(|&b| b != b'\n').map_or(0, |i| i + 1);
    &s[..end]
}

/// `tail -n N`.
pub fn tail_lines(text: &[u8], n: usize) -> &[u8] {
    if n == 0 {
        return &[];
    }
    let end = text.strip_suffix(b"\n").map_or(text.len(), <[u8]>::len);
    let mut seen = 0;
    for i in (0..end).rev() {
        if text[i] == b'\n' {
            seen += 1;
            if seen == n {
                return &text[i + 1..];
            }
        }
    }
    text
}

pub fn replace_all(haystack: &[u8], needle: &[u8], with: &[u8]) -> Vec<u8> {
    if needle.is_empty() {
        return haystack.to_vec();
    }
    let mut out = Vec::with_capacity(haystack.len());
    let mut i = 0;
    while i < haystack.len() {
        if haystack[i..].starts_with(needle) {
            out.extend_from_slice(with);
            i += needle.len();
        } else {
            out.push(haystack[i]);
            i += 1;
        }
    }
    out
}

pub fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

pub fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    find(haystack, needle).is_some()
}

pub fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// Joins lines, each followed by a newline.
pub fn join_lines<T: AsRef<[u8]>>(lines: &[T]) -> Vec<u8> {
    let mut out = Vec::new();
    for line in lines {
        out.extend_from_slice(line.as_ref());
        out.push(b'\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_count_a_last_line_without_newline() {
        assert_eq!(lines(b""), Vec::<&[u8]>::new());
        assert_eq!(lines(b"\n"), vec![&b""[..]]);
        assert_eq!(lines(b"a\nb"), vec![&b"a"[..], b"b"]);
        assert_eq!(lines(b"a\n\n"), vec![&b"a"[..], b""]);
        assert_eq!(complete_lines(b"a\nb"), vec![&b"a"[..]]);
        assert_eq!(complete_lines(b"a\nb\n"), vec![&b"a"[..], b"b"]);
    }

    #[test]
    fn read_fields_keeps_the_rest_in_the_last() {
        assert_eq!(
            read_fields(b"  a b\tc  d  ", 3),
            vec![&b"a"[..], b"b", b"c  d"]
        );
        assert_eq!(read_fields(b"a", 3), vec![&b"a"[..], b"", b""]);
        assert_eq!(fields(b" x\t y  "), vec![&b"x"[..], b"y"]);
    }

    #[test]
    fn tail_as_gnu_tail() {
        assert_eq!(tail_lines(b"a\nb\nc\n", 2), b"b\nc\n");
        assert_eq!(tail_lines(b"a\nb\nc", 2), b"b\nc");
        assert_eq!(tail_lines(b"a\n", 5), b"a\n");
        assert_eq!(chomp(b"x\n\n"), b"x");
    }
}
