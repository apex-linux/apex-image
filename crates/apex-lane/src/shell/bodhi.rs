use crate::core::hold::bodhi_types;
use crate::shell::cmd::{Cmd, Program, Runner, Stderr};

pub trait Bodhi {
    /// The update types of the build `nvr`, joined by spaces; empty when it is not in
    /// Bodhi or the query failed.
    fn types(&self, nvr: &str) -> String;
}

/// Percent-encodes everything but RFC 3986's unreserved characters: a `+` in an NVR must
/// not reach Bodhi as a space.
pub fn query_value(nvr: &str) -> String {
    nvr.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// `curl -fsS --max-time 30`, no retry: an unanswered query counts as a security update.
#[derive(Debug)]
pub struct CurlBodhi<'a, R: Runner + ?Sized> {
    pub runner: &'a R,
}

impl<R: Runner + ?Sized> Bodhi for CurlBodhi<'_, R> {
    fn types(&self, nvr: &str) -> String {
        let cmd = Cmd::new(Program::Curl)
            .args(["-fsS", "--max-time", "30"])
            .arg(format!(
                "https://bodhi.fedoraproject.org/updates/?builds={}",
                query_value(nvr)
            ))
            .capture()
            .stderr(Stderr::Null);
        match self.runner.run(&cmd) {
            Ok(out) if out.ok() => bodhi_types(&out.stdout),
            _ => String::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plus_is_encoded() {
        assert_eq!(query_value("gtk4-4.24.0-1.fc45"), "gtk4-4.24.0-1.fc45");
        assert_eq!(
            query_value("libsigc++30-3.6.0-1.fc45"),
            "libsigc%2B%2B30-3.6.0-1.fc45"
        );
    }
}
