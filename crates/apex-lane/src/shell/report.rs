//! The log on stderr; on GitHub Actions, workflow commands and the step summary.

use std::io::Write as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Default)]
pub struct Reporter {
    pub github: bool,
    pub summary_file: Option<PathBuf>,
    /// Takes the log instead of stderr (tests).
    pub capture: Option<Arc<Mutex<Vec<u8>>>>,
}

impl Reporter {
    pub fn from_env() -> Self {
        Self {
            github: std::env::var("GITHUB_ACTIONS").is_ok_and(|v| v == "true"),
            summary_file: std::env::var_os("GITHUB_STEP_SUMMARY")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from),
            capture: None,
        }
    }

    pub fn capturing() -> Self {
        Self {
            capture: Some(Arc::default()),
            ..Self::default()
        }
    }

    pub fn captured(&self) -> Vec<u8> {
        self.capture
            .as_ref()
            .and_then(|c| c.lock().ok().map(|b| b.clone()))
            .unwrap_or_default()
    }

    pub fn raw(&self, bytes: &[u8]) {
        if let Some(capture) = &self.capture {
            if let Ok(mut buf) = capture.lock() {
                buf.extend_from_slice(bytes);
            }
            return;
        }
        let mut err = std::io::stderr().lock();
        let _ = err.write_all(bytes);
        let _ = err.flush();
    }

    pub fn log(&self, text: &str) {
        self.raw(format!("{text}\n").as_bytes());
    }

    fn annotated(&self, command: &str, local: &str, text: &str) {
        if self.github {
            self.log(&format!("::{command}::{text}"));
        } else {
            self.log(&format!("{local}: {text}"));
        }
    }

    pub fn notice(&self, text: &str) {
        self.annotated("notice", "notice", text);
    }

    pub fn warn(&self, text: &str) {
        self.annotated("warning", "warning", text);
    }

    pub fn error(&self, text: &str) {
        self.annotated("error", "error", text);
    }

    pub fn usage_error(&self, text: &str) {
        self.annotated("error", "usage error", text);
    }

    pub fn group(&self, title: &str) {
        if self.github {
            self.log(&format!("::group::{title}"));
        } else {
            self.log(&format!("== {title}"));
        }
    }

    pub fn endgroup(&self) {
        if self.github {
            self.log("::endgroup::");
        }
    }

    pub fn summary(&self, lines: &[String]) {
        let mut text = lines.join("\n");
        text.push('\n');
        let written = self.summary_file.as_ref().is_some_and(|path| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .and_then(|mut f| f.write_all(text.as_bytes()))
                .is_ok()
        });
        if !written {
            self.raw(text.as_bytes());
        }
    }
}
