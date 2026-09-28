//! `spec-edit`: anchored edits to Fedora's spec, and the series' Patch lines.

use crate::core::ere::Ere;
use crate::core::names::is_release_value;
use crate::core::text::{self, is_space};
use crate::error::ConfigError;

pub const PLACEHOLDERS: [&str; 3] = ["APEX_RELEASE", "PIN_EVR", "SOURCE1"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    After,
    Replace,
}

impl Op {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::After => "after",
            Self::Replace => "replace",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Block {
    pub op: Op,
    pub ere: Ere,
    pub text: Vec<Vec<u8>>,
}

#[derive(Debug, Clone)]
pub struct SpecEdit {
    pub blocks: Vec<Block>,
}

fn is_blank_or_comment(line: &[u8]) -> bool {
    let rest = text::trim_start_space(line);
    rest.is_empty() || rest[0] == b'#'
}

/// `@[A-Z0-9_]+@` in what is left once the known placeholders are removed, in order.
fn unknown_placeholder(line: &[u8]) -> Option<String> {
    let mut rest = line.to_vec();
    for p in PLACEHOLDERS {
        rest = text::replace_all(&rest, format!("@{p}@").as_bytes(), b"");
    }
    let is_name = |c: u8| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_';
    let mut i = 0;
    while i < rest.len() {
        if rest[i] == b'@' {
            let len = rest[i + 1..].iter().take_while(|&&c| is_name(c)).count();
            if len > 0 && rest.get(i + 1 + len) == Some(&b'@') {
                return Some(text::lossy(&rest[i..i + len + 2]));
            }
        }
        i += 1;
    }
    None
}

pub fn parse(file: &str, bytes: &[u8]) -> Result<SpecEdit, ConfigError> {
    let err = |n: usize, msg: &str| ConfigError(format!("{file}:{n}: {msg}"));
    let mut blocks: Vec<Block> = Vec::new();
    let mut open = false;
    for (i, line) in text::lines(bytes).into_iter().enumerate() {
        let n = i + 1;
        if !open {
            if is_blank_or_comment(line) {
                continue;
            }
            let (op, ere) = if let Some(ere) = line.strip_prefix(b"after ") {
                (Op::After, ere)
            } else if let Some(ere) = line.strip_prefix(b"replace ") {
                (Op::Replace, ere)
            } else {
                return Err(err(n, "expected 'after ERE' or 'replace ERE'"));
            };
            if ere.is_empty() {
                return Err(err(n, "expected 'after ERE' or 'replace ERE'"));
            }
            let ere = Ere::new(ere).map_err(|e| err(n, &format!("the ERE: {e}")))?;
            blocks.push(Block {
                op,
                ere,
                text: Vec::new(),
            });
            open = true;
        } else if line == b"end" {
            if blocks.last().is_none_or(|b| b.text.is_empty()) {
                return Err(err(n, "a block without text"));
            }
            open = false;
        } else if let Some(text_line) = line.strip_prefix(b"\t") {
            if let Some(p) = unknown_placeholder(text_line) {
                return Err(err(n, &format!("unknown placeholder {p}")));
            }
            if let Some(block) = blocks.last_mut() {
                block.text.push(text_line.to_vec());
            }
        } else {
            return Err(err(
                n,
                "a text line starts with one tab; a block ends with 'end'",
            ));
        }
    }
    if open {
        return Err(ConfigError(format!("{file}: the last block has no 'end'")));
    }
    if blocks.is_empty() {
        return Err(ConfigError(format!("{file} has no edit")));
    }
    Ok(SpecEdit { blocks })
}

/// What fills the placeholders; an empty value is no value.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Values {
    pub apex_release: String,
    pub pin_evr: String,
    pub source1: String,
}

impl Values {
    fn get(&self, placeholder: &str) -> &str {
        match placeholder {
            "APEX_RELEASE" => &self.apex_release,
            "PIN_EVR" => &self.pin_evr,
            _ => &self.source1,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApplyError {
    /// The family holds: the reason is [`ApplyError::reason`].
    Anchor {
        op: Op,
        ere: Vec<u8>,
        hits: usize,
    },
    MissingValue(&'static str),
    UnsafeValue(&'static str, String),
}

impl ApplyError {
    pub fn reason(&self) -> Vec<u8> {
        match self {
            Self::Anchor { op, ere, hits } => {
                let mut out = format!("spec-edit: '{} ", op.as_str()).into_bytes();
                out.extend_from_slice(ere);
                out.extend_from_slice(
                    format!("' matches {hits} lines of the spec, not 1").as_bytes(),
                );
                out
            }
            Self::MissingValue(p) => format!("spec-edit: no value for @{p}@").into_bytes(),
            Self::UnsafeValue(p, v) => {
                format!("spec-edit: unsafe value for @{p}@: '{v}'").into_bytes()
            }
        }
    }
}

fn fill(block: &Block, values: &Values) -> Result<Vec<u8>, ApplyError> {
    let mut filled = text::join_lines(&block.text);
    for p in PLACEHOLDERS {
        let token = format!("@{p}@");
        if !text::contains(&filled, token.as_bytes()) {
            continue;
        }
        let value = values.get(p);
        if value.is_empty() {
            return Err(ApplyError::MissingValue(p));
        }
        if !is_release_value(value) {
            return Err(ApplyError::UnsafeValue(p, value.to_owned()));
        }
        filled = text::replace_all(&filled, token.as_bytes(), value.as_bytes());
    }
    Ok(filled)
}

/// Applies the blocks in order. `log` gets `spec-edit: <op> line <n>: <ere>` per block.
pub fn apply(
    edit: &SpecEdit,
    spec: &[u8],
    values: &Values,
    log: &mut dyn FnMut(Vec<u8>),
) -> Result<Vec<u8>, ApplyError> {
    let mut spec = spec.to_vec();
    for block in &edit.blocks {
        let lines = text::lines(&spec);
        let hits: Vec<usize> = lines
            .iter()
            .enumerate()
            .filter(|(_, line)| block.ere.is_match(line))
            .map(|(i, _)| i)
            .collect();
        let [at] = hits[..] else {
            return Err(ApplyError::Anchor {
                op: block.op,
                ere: block.ere.source().to_vec(),
                hits: hits.len(),
            });
        };
        let filled = fill(block, values)?;
        let mut out = text::join_lines(&lines[..at]);
        if block.op == Op::After {
            out.extend_from_slice(lines[at]);
            out.push(b'\n');
        }
        out.extend_from_slice(&filled);
        out.extend_from_slice(&text::join_lines(&lines[at + 1..]));
        let mut message =
            format!("spec-edit: {} line {}: ", block.op.as_str(), at + 1).into_bytes();
        message.extend_from_slice(block.ere.source());
        log(message);
        spec = out;
    }
    Ok(spec)
}

/// `^<word>[0-9]*[[:space:]]*:`
fn is_tag(line: &[u8], word: &[u8]) -> bool {
    let Some(rest) = line.strip_prefix(word) else {
        return false;
    };
    let rest = &rest[rest.iter().take_while(|c| c.is_ascii_digit()).count()..];
    let rest = &rest[rest.iter().take_while(|&&c| is_space(c)).count()..];
    rest.first() == Some(&b':')
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NoAnchor;

pub fn patch_lines(series: &[String]) -> Vec<u8> {
    let lines: Vec<String> = series
        .iter()
        .enumerate()
        .map(|(i, p)| format!("Patch{}:      apex-{p}", 1001 + i))
        .collect();
    text::join_lines(&lines)
}

/// The Patch lines after the spec's last Patch line, or its last Source line.
pub fn insert_patch_lines(spec: &[u8], patch_lines: &[u8]) -> Result<Vec<u8>, NoAnchor> {
    let lines = text::lines(spec);
    let last = |word: &[u8]| lines.iter().rposition(|line| is_tag(line, word));
    let at = last(b"Patch").or_else(|| last(b"Source")).ok_or(NoAnchor)?;
    let mut out = text::join_lines(&lines[..=at]);
    out.extend_from_slice(patch_lines);
    out.extend_from_slice(&text::join_lines(&lines[at + 1..]));
    Ok(out)
}

/// `^%(autosetup|autopatch)([[:space:]]|$)`
pub fn uses_autosetup(spec: &[u8]) -> bool {
    text::lines(spec).into_iter().any(|line| {
        [&b"%autosetup"[..], b"%autopatch"].iter().any(|word| {
            line.strip_prefix(*word)
                .is_some_and(|rest| rest.first().is_none_or(|&c| is_space(c)))
        })
    })
}

/// `^Patch1[0-9]{3}[[:space:]]*:`
pub fn has_patch_1nnn(spec: &[u8]) -> bool {
    text::lines(spec).into_iter().any(|line| {
        line.strip_prefix(b"Patch1").is_some_and(|rest| {
            rest.len() >= 3 && rest[..3].iter().all(u8::is_ascii_digit) && {
                let tail = &rest[3..];
                let tail = &tail[tail.iter().take_while(|&&c| is_space(c)).count()..];
                tail.first() == Some(&b':')
            }
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholders() {
        assert_eq!(unknown_placeholder(b"x @APEX_RELEASE@ @PIN_EVR@"), None);
        assert_eq!(unknown_placeholder(b"@NOPE@").as_deref(), Some("@NOPE@"));
        assert_eq!(
            unknown_placeholder(b"@A@APEX_RELEASE@B@").as_deref(),
            Some("@AB@"),
            "removal runs first, as in the shell parser"
        );
        assert_eq!(unknown_placeholder(b"a@b.c@d"), None);
    }

    #[test]
    fn tags() {
        assert!(is_tag(b"Patch:          x", b"Patch"));
        assert!(is_tag(b"Patch12 :x", b"Patch"));
        assert!(!is_tag(b"PatchX: x", b"Patch"));
        assert!(has_patch_1nnn(b"Patch1001:  x\n"));
        assert!(!has_patch_1nnn(b"Patch10001:  x\n"));
        assert!(uses_autosetup(b"%autosetup -S git\n"));
        assert!(uses_autosetup(b"%autopatch\n"));
        assert!(!uses_autosetup(b"%autosetupx\n"));
    }
}
