//! spec-edit's anchors: the POSIX ERE subset of packaging/README.md, matched per line on
//! bytes, as `grep -E` does in the C locale.

use std::fmt::Write as _;

use regex::bytes::{Regex, RegexBuilder};

#[derive(Debug, Clone)]
pub struct Ere {
    source: Vec<u8>,
    regex: Regex,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct EreError(pub String);

const CLASSES: [&str; 12] = [
    "alpha", "digit", "alnum", "upper", "lower", "space", "blank", "punct", "print", "graph",
    "cntrl", "xdigit",
];
const MAX_COUNT: u32 = 255;

impl Ere {
    pub fn new(source: &[u8]) -> Result<Self, EreError> {
        let pattern = translate(source)?;
        let regex = RegexBuilder::new(&pattern)
            .unicode(false)
            .build()
            .map_err(|e| EreError(format!("the ERE does not compile: {e}")))?;
        Ok(Self {
            source: source.to_vec(),
            regex,
        })
    }

    pub fn is_match(&self, line: &[u8]) -> bool {
        self.regex.is_match(line)
    }

    pub fn source(&self) -> &[u8] {
        &self.source
    }
}

pub fn translate(source: &[u8]) -> Result<String, EreError> {
    let mut parser = Parser {
        s: source,
        i: 0,
        depth: 0,
    };
    let out = parser.alternation()?;
    if parser.i < source.len() {
        return Err(EreError("an unmatched )".into()));
    }
    Ok(out)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
    depth: usize,
}

fn error<T>(message: impl Into<String>) -> Result<T, EreError> {
    Err(EreError(message.into()))
}

fn byte(b: u8) -> String {
    if b.is_ascii_alphanumeric() || b == b'_' || b == b' ' {
        char::from(b).to_string()
    } else {
        format!("\\x{b:02X}")
    }
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn peek_at(&self, offset: usize) -> Option<u8> {
        self.s.get(self.i + offset).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let b = self.peek()?;
        self.i += 1;
        Some(b)
    }

    fn alternation(&mut self) -> Result<String, EreError> {
        let mut out = self.branch()?;
        while self.peek() == Some(b'|') {
            self.i += 1;
            out.push('|');
            out.push_str(&self.branch()?);
        }
        Ok(out)
    }

    fn branch(&mut self) -> Result<String, EreError> {
        let mut out = String::new();
        loop {
            match self.peek() {
                None | Some(b'|') => break,
                Some(b')') if self.depth > 0 => break,
                _ => out.push_str(&self.piece()?),
            }
        }
        if out.is_empty() {
            return error("an empty alternative or group");
        }
        Ok(out)
    }

    fn piece(&mut self) -> Result<String, EreError> {
        let (mut out, repeatable) = self.atom()?;
        while let Some(quantifier) = self.quantifier()? {
            if !repeatable {
                return error(format!("{quantifier} follows an anchor"));
            }
            out = format!("(?:{out}){quantifier}");
        }
        Ok(out)
    }

    fn atom(&mut self) -> Result<(String, bool), EreError> {
        let Some(c) = self.next() else {
            return error("an empty ERE");
        };
        Ok(match c {
            b'(' => {
                self.depth += 1;
                let inner = self.alternation()?;
                if self.next() != Some(b')') {
                    return error("an unmatched (");
                }
                self.depth -= 1;
                (format!("(?:{inner})"), true)
            }
            b')' => return error("an unmatched )"),
            b'.' => (".".into(), true),
            b'^' => ("^".into(), false),
            b'$' => ("$".into(), false),
            b'[' => (self.bracket()?, true),
            b'\\' => (self.escape()?, true),
            b'*' | b'+' | b'?' => {
                return error(format!("{} follows nothing it could repeat", char::from(c)));
            }
            b'{' => {
                return error("a { that starts no interval: write \\{ or [{] for the character");
            }
            other => (byte(other), true),
        })
    }

    fn escape(&mut self) -> Result<String, EreError> {
        match self.next() {
            None => error("a trailing backslash"),
            Some(
                c @ (b'.' | b'[' | b']' | b'(' | b')' | b'{' | b'}' | b'*' | b'+' | b'?' | b'|'
                | b'^' | b'$' | b'\\' | b'/'),
            ) => Ok(byte(c)),
            Some(c @ b'1'..=b'9') => error(format!(
                "the back-reference \\{} is not in the ERE subset",
                char::from(c)
            )),
            Some(c @ (b'w' | b'W' | b's' | b'S' | b'b' | b'B' | b'<' | b'>' | b'`' | b'\'')) => {
                error(format!(
                    "the GNU escape \\{} is not in the ERE subset",
                    char::from(c)
                ))
            }
            Some(c) => error(format!(
                "\\{} is not an escape of the ERE subset: write the character, or put it in [ ]",
                char::from(c).escape_default()
            )),
        }
    }

    fn quantifier(&mut self) -> Result<Option<String>, EreError> {
        match self.peek() {
            Some(c @ (b'*' | b'+' | b'?')) => {
                self.i += 1;
                Ok(Some(char::from(c).to_string()))
            }
            Some(b'{') => {
                self.i += 1;
                self.interval().map(Some)
            }
            _ => Ok(None),
        }
    }

    fn number(&mut self) -> Result<Option<u32>, EreError> {
        let start = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
            self.i += 1;
        }
        if self.i == start {
            return Ok(None);
        }
        let digits = std::str::from_utf8(&self.s[start..self.i]).unwrap_or("");
        match digits.parse::<u32>() {
            Ok(n) if n <= MAX_COUNT => Ok(Some(n)),
            _ => error(format!("an interval count above {MAX_COUNT}")),
        }
    }

    fn interval(&mut self) -> Result<String, EreError> {
        let invalid = || error("a { that starts no interval: write \\{ or [{] for the character");
        let min = self.number()?;
        let out = if self.peek() == Some(b',') {
            self.i += 1;
            let max = self.number()?;
            match (min, max) {
                (None, None) => return invalid(),
                (Some(m), None) => format!("{{{m},}}"),
                (m, Some(n)) => {
                    let m = m.unwrap_or(0);
                    if m > n {
                        return error(format!("the interval {{{m},{n}}} counts down"));
                    }
                    format!("{{{m},{n}}}")
                }
            }
        } else {
            match min {
                Some(m) => format!("{{{m}}}"),
                None => return invalid(),
            }
        };
        if self.next() != Some(b'}') {
            return invalid();
        }
        Ok(out)
    }

    fn bracket(&mut self) -> Result<String, EreError> {
        let mut out = String::from("[");
        if self.peek() == Some(b'^') {
            self.i += 1;
            out.push('^');
        }
        let mut first = true;
        loop {
            let Some(c) = self.next() else {
                return error("an unterminated [");
            };
            if c == b']' && !first {
                break;
            }
            let at_start = first;
            first = false;
            if !c.is_ascii() {
                return error("a non-ASCII byte inside [ ] (its meaning depends on the locale)");
            }
            if c == b'[' && matches!(self.peek(), Some(b':' | b'=' | b'.')) {
                out.push_str(&self.class()?);
                continue;
            }
            if self.peek() == Some(b'-') && self.peek_at(1).is_some_and(|e| e != b']') {
                self.i += 1;
                let Some(end) = self.next() else {
                    return error("an unterminated [");
                };
                if !end.is_ascii() {
                    return error(
                        "a non-ASCII byte inside [ ] (its meaning depends on the locale)",
                    );
                }
                if end == b'[' && matches!(self.peek(), Some(b':' | b'=' | b'.')) {
                    return error("a range cannot end in a class");
                }
                if end < c {
                    return error(format!(
                        "the range {}-{} runs backwards",
                        char::from(c),
                        char::from(end)
                    ));
                }
                if self.peek() == Some(b'-') && self.peek_at(1).is_some_and(|e| e != b']') {
                    return error("a - inside [ ] must come first, last, or in one range");
                }
                let _ = write!(out, "\\x{c:02X}-\\x{end:02X}");
                continue;
            }
            if c == b'-' && !at_start && self.peek() != Some(b']') {
                return error("a - inside [ ] must come first, last, or in one range");
            }
            let _ = write!(out, "\\x{c:02X}");
        }
        out.push(']');
        Ok(out)
    }

    fn class(&mut self) -> Result<String, EreError> {
        let kind = self.next();
        if kind != Some(b':') {
            return error("[= =] and [. .] are not in the ERE subset");
        }
        let start = self.i;
        while self.i + 1 < self.s.len() && !(self.s[self.i] == b':' && self.s[self.i + 1] == b']') {
            self.i += 1;
        }
        if self.i + 1 >= self.s.len() {
            return error("an unterminated [: :]");
        }
        let name = String::from_utf8_lossy(&self.s[start..self.i]).into_owned();
        self.i += 2;
        if !CLASSES.contains(&name.as_str()) {
            return error(format!("an unknown class [:{name}:]"));
        }
        Ok(format!("[:{name}:]"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(ere: &str, line: &str) -> bool {
        Ere::new(ere.as_bytes()).unwrap().is_match(line.as_bytes())
    }

    fn refused(ere: &str) -> String {
        Ere::new(ere.as_bytes()).unwrap_err().0
    }

    #[test]
    fn the_committed_anchors() {
        assert!(matches(
            r"^Release:[[:space:]]+%autorelease$",
            "Release:        %autorelease"
        ));
        assert!(!matches(
            r"^Release:[[:space:]]+%autorelease$",
            "Release:        %autorelease -e x"
        ));
        assert!(matches(r"^Source0:", "Source0:        https://x"));
        assert!(matches(
            r"^Requires:[[:space:]]+mutter%\{\?_isa\}[[:space:]]",
            "Requires:       mutter%{?_isa} >= %{mutter_version}"
        ));
        assert!(matches(r"^%autosetup[[:space:]]", "%autosetup -S git -n x"));
        assert!(matches(
            r"^BuildRequires:[[:space:]]+mutter-devel[[:space:]]",
            "BuildRequires:  mutter-devel >= %{mutter_version}"
        ));
    }

    #[test]
    fn constructs() {
        assert!(matches("a|b", "xb"));
        assert!(matches("^(ab)+$", "abab"));
        assert!(!matches("^(ab)+$", "aba"));
        assert!(matches("^a{2,3}$", "aaa") && !matches("^a{2,3}$", "aaaa"));
        assert!(matches("^a{,2}$", "") && matches("^a{2,}$", "aaaaa"));
        assert!(matches("^[]a]+$", "]a]") && matches("^[^]a]$", "b"));
        assert!(matches("^[a-]$", "-") && matches("^[-a]$", "-"));
        assert!(matches(r"^[\]$", "\\"));
        assert!(
            matches("^a+?$", "") && matches("^a+?$", "aa"),
            "a+? is (a+)?"
        );
        assert!(matches("x}y", "x}y") && matches("x]", "x]"));
        assert!(Ere::new(&[b'^', 0xe9, b'$']).unwrap().is_match(&[0xe9]));
        assert!(
            Ere::new(b"^.$").unwrap().is_match(&[0xe9]),
            "a byte, not a character"
        );
    }

    #[test]
    fn refusals() {
        for ere in [
            r"(a)\1",
            r"\w",
            r"\bx",
            r"a{",
            "a{x}",
            "{1}",
            "a{3,1}",
            "()",
            "a|",
            "|a",
            "(a",
            "a)",
            "*a",
            "^*",
            "[a",
            "[[=a=]]",
            "[[.a.]]",
            "[[:word:]]",
            "[z-a]",
            r"a\",
            r"\n",
            "a{256}",
            "[a-c-e]",
        ] {
            assert!(Ere::new(ere.as_bytes()).is_err(), "{ere} must be refused");
        }
        assert!(refused("a{").contains("starts no interval"));
        assert!(refused(r"\1").contains("back-reference"));
        assert!(Ere::new(&[b'[', 0xe9, b']']).is_err());
    }
}
