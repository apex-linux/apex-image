use crate::core::utc::UtcSecond;
use crate::shell::cmd::{Cmd, Program, Runner, Stderr};

pub const RELEASES_JSON: &str = "https://www.kernel.org/releases.json";

pub trait KernelOrg {
    /// When kernel.org released `version` (`7.3` for 7.3.0); `None` when releases.json
    /// no longer lists it or cannot be read.
    fn released(&self, version: &str) -> Option<UtcSecond>;
}

pub fn released_in(json: &[u8], version: &str) -> Option<UtcSecond> {
    let doc: serde_json::Value = serde_json::from_slice(json).ok()?;
    doc.get("releases")?
        .as_array()?
        .iter()
        .find(|r| r.get("version").and_then(serde_json::Value::as_str) == Some(version))?
        .get("released")?
        .get("timestamp")?
        .as_i64()
        .map(UtcSecond)
}

#[derive(Debug)]
pub struct CurlKernelOrg<'a, R: Runner + ?Sized> {
    pub runner: &'a R,
}

impl<R: Runner + ?Sized> KernelOrg for CurlKernelOrg<'_, R> {
    fn released(&self, version: &str) -> Option<UtcSecond> {
        let cmd = Cmd::new(Program::Curl)
            .args(["-fsSL", "--retry", "3", "--max-time", "60", RELEASES_JSON])
            .capture()
            .stderr(Stderr::Null);
        match self.runner.run(&cmd) {
            Ok(out) if out.ok() => released_in(&out.stdout, version),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn releases_json() {
        let json = br#"{"releases":[{"moniker":"stable","version":"7.3.1","released":{"timestamp":1795000000,"isodate":"2026-11-18"}},{"moniker":"mainline","version":"7.4-rc1"}]}"#;
        assert_eq!(released_in(json, "7.3.1"), Some(UtcSecond(1_795_000_000)));
        assert_eq!(released_in(json, "7.3"), None);
        assert_eq!(released_in(json, "7.4-rc1"), None);
        assert_eq!(released_in(b"not json", "7.3.1"), None);
    }
}
