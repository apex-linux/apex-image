//! `series`: one `NNNN-name.patch` per line, in order; `#` starts a comment.

use crate::core::names::is_patch_name;
use crate::core::text;
use crate::error::ConfigError;

/// Whether the series must name existing files, and how to tell.
#[derive(Clone, Copy)]
pub enum Files<'a> {
    Check {
        dir: &'a str,
        exists: &'a dyn Fn(&str) -> bool,
    },
    /// `export` writes the new patches itself.
    Skip,
}

impl std::fmt::Debug for Files<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Check { dir, .. } => write!(f, "Check({dir})"),
            Self::Skip => write!(f, "Skip"),
        }
    }
}

pub fn parse(file: &str, bytes: &[u8], files: Files<'_>) -> Result<Vec<String>, ConfigError> {
    let mut patches: Vec<String> = Vec::new();
    for line in text::lines(bytes) {
        let line = line
            .iter()
            .position(|&b| b == b'#')
            .map_or(line, |hash| &line[..hash]);
        let line = text::trim_end_space(text::trim_start_space(line));
        if line.is_empty() {
            continue;
        }
        let name = String::from_utf8_lossy(line).into_owned();
        if !is_patch_name(&name) {
            return Err(ConfigError(format!(
                "{file}: '{name}' is not a NNNN-name.patch file name"
            )));
        }
        if let Files::Check { dir, exists } = files
            && !exists(&name)
        {
            return Err(ConfigError(format!("{file}: '{name}' not found in {dir}")));
        }
        if patches.contains(&name) {
            return Err(ConfigError(format!("{file} lists '{name}' twice")));
        }
        patches.push(name);
    }
    if patches.is_empty() {
        return Err(ConfigError(format!("{file} enables no patch")));
    }
    Ok(patches)
}
