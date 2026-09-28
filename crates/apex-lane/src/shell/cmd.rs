//! Child processes: programs at absolute paths, argv built from typed values.

use std::ffi::{OsStr, OsString};
use std::fmt;
use std::fs::File;
use std::io::Read as _;
use std::os::fd::AsFd as _;
use std::os::unix::process::ExitStatusExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::error::{Result, infra};
use crate::shell::report::Reporter;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Program {
    Bash,
    Chown,
    Cp,
    Cpio,
    Curl,
    Diff,
    Dnf5,
    Git,
    Gpg,
    Podman,
    Rm,
    Rpm,
    Rpm2cpio,
    Rpmbuild,
    Rpmkeys,
    Rpmspec,
    Sudo,
    Tar,
}

impl Program {
    pub fn path(self) -> &'static str {
        match self {
            Self::Bash => "/usr/bin/bash",
            Self::Chown => "/usr/bin/chown",
            Self::Cp => "/usr/bin/cp",
            Self::Cpio => "/usr/bin/cpio",
            Self::Curl => "/usr/bin/curl",
            Self::Diff => "/usr/bin/diff",
            Self::Dnf5 => "/usr/bin/dnf5",
            Self::Git => "/usr/bin/git",
            Self::Gpg => "/usr/bin/gpg",
            Self::Podman => "/usr/bin/podman",
            Self::Rm => "/usr/bin/rm",
            Self::Rpm => "/usr/bin/rpm",
            Self::Rpm2cpio => "/usr/bin/rpm2cpio",
            Self::Rpmbuild => "/usr/bin/rpmbuild",
            Self::Rpmkeys => "/usr/bin/rpmkeys",
            Self::Rpmspec => "/usr/bin/rpmspec",
            Self::Sudo => "/usr/bin/sudo",
            Self::Tar => "/usr/bin/tar",
        }
    }

    pub fn name(self) -> &'static str {
        self.path().rsplit('/').next().unwrap_or_default()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Stdout {
    Inherit,
    Null,
    Capture,
    /// Truncated, like `>FILE`.
    File(PathBuf),
    /// `>>FILE`.
    Append(PathBuf),
    /// Our stderr, like `>&2`.
    Stderr,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stderr {
    Inherit,
    Null,
    Capture,
    /// Wherever stdout goes, like `2>&1`.
    ToStdout,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cmd {
    pub program: Program,
    pub args: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
    pub stdout: Stdout,
    pub stderr: Stderr,
}

impl Cmd {
    pub fn new(program: Program) -> Self {
        Self {
            program,
            args: Vec::new(),
            env: Vec::new(),
            cwd: None,
            stdout: Stdout::Inherit,
            stderr: Stderr::Inherit,
        }
    }

    #[must_use]
    pub fn arg(mut self, arg: impl AsRef<OsStr>) -> Self {
        self.args.push(arg.as_ref().to_owned());
        self
    }

    #[must_use]
    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.args
            .extend(args.into_iter().map(|a| a.as_ref().to_owned()));
        self
    }

    #[must_use]
    pub fn env(mut self, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> Self {
        self.env
            .push((key.as_ref().to_owned(), value.as_ref().to_owned()));
        self
    }

    #[must_use]
    pub fn cwd(mut self, dir: impl Into<PathBuf>) -> Self {
        self.cwd = Some(dir.into());
        self
    }

    #[must_use]
    pub fn stdout(mut self, stdout: Stdout) -> Self {
        self.stdout = stdout;
        self
    }

    #[must_use]
    pub fn stderr(mut self, stderr: Stderr) -> Self {
        self.stderr = stderr;
        self
    }

    #[must_use]
    pub fn capture(self) -> Self {
        self.stdout(Stdout::Capture)
    }

    /// `>FILE 2>&1`.
    #[must_use]
    pub fn log_to(self, file: impl Into<PathBuf>) -> Self {
        self.stdout(Stdout::File(file.into()))
            .stderr(Stderr::ToStdout)
    }

    /// The same command through sudo, unless this process is root already.
    #[must_use]
    pub fn privileged(self, is_root: bool) -> Self {
        if is_root {
            return self;
        }
        let mut args = vec![OsString::from(self.program.path())];
        args.extend(self.args);
        Self {
            program: Program::Sudo,
            args,
            ..self
        }
    }
}

impl fmt::Display for Cmd {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.program.name())?;
        for a in &self.args {
            write!(f, " {}", a.to_string_lossy())?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Outcome {
    /// The exit status, or 128 plus the signal, as a shell reports it.
    pub code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Outcome {
    pub fn ok(&self) -> bool {
        self.code == 0
    }
}

pub trait Runner {
    fn run(&self, cmd: &Cmd) -> Result<Outcome>;
    /// `first | second`, both statuses reported (pipefail).
    fn pipe(&self, first: &Cmd, second: &Cmd) -> Result<(Outcome, Outcome)>;
    fn sleep(&self, duration: Duration);
}

/// Runs processes for real. On the VM side the children get a cleared environment.
#[derive(Debug, Clone)]
pub struct StdRunner {
    base_env: Option<Vec<(OsString, OsString)>>,
}

impl StdRunner {
    pub fn inherit() -> Self {
        Self { base_env: None }
    }

    pub fn cleared(home: &Path) -> Self {
        Self {
            base_env: Some(vec![
                ("PATH".into(), "/usr/bin:/usr/sbin".into()),
                ("LANG".into(), "C.UTF-8".into()),
                ("HOME".into(), home.into()),
            ]),
        }
    }

    fn command(&self, cmd: &Cmd) -> Command {
        let mut c = Command::new(cmd.program.path());
        c.args(&cmd.args).stdin(Stdio::null());
        if let Some(base) = &self.base_env {
            c.env_clear().envs(base.iter().map(|(k, v)| (k, v)));
        }
        c.envs(cmd.env.iter().map(|(k, v)| (k, v)));
        if let Some(dir) = &cmd.cwd {
            c.current_dir(dir);
        }
        c
    }
}

fn spawn_error(cmd: &Cmd, e: &std::io::Error) -> crate::LaneError {
    infra(format!("cannot run {}: {e}", cmd.program.path()))
}

fn stderr_handle() -> std::io::Result<Stdio> {
    Ok(Stdio::from(std::io::stderr().as_fd().try_clone_to_owned()?))
}

fn code_of(status: std::process::ExitStatus) -> i32 {
    status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

impl Runner for StdRunner {
    fn run(&self, cmd: &Cmd) -> Result<Outcome> {
        let io = |e: std::io::Error| spawn_error(cmd, &e);
        let mut c = self.command(cmd);
        let mut merged_capture = None;
        match (&cmd.stdout, cmd.stderr) {
            (Stdout::Capture, Stderr::ToStdout) => {
                let (reader, writer) = std::io::pipe().map_err(io)?;
                c.stdout(writer.try_clone().map_err(io)?).stderr(writer);
                merged_capture = Some(reader);
            }
            (stdout, stderr) => {
                let file = match stdout {
                    Stdout::File(path) => Some(File::create(path).map_err(io)?),
                    Stdout::Append(path) => Some(
                        File::options()
                            .create(true)
                            .append(true)
                            .open(path)
                            .map_err(io)?,
                    ),
                    _ => None,
                };
                let err: Stdio = match (stderr, &file, stdout) {
                    (Stderr::Inherit, _, _) => Stdio::inherit(),
                    (Stderr::Null, _, _) | (Stderr::ToStdout, None, Stdout::Null) => Stdio::null(),
                    (Stderr::Capture, _, _) => Stdio::piped(),
                    // One open file for both, as `2>&1` shares the descriptor.
                    (Stderr::ToStdout, Some(f), _) => f.try_clone().map_err(io)?.into(),
                    (Stderr::ToStdout, None, _) => stderr_handle().map_err(io)?,
                };
                let out: Stdio = match (stdout, file) {
                    (_, Some(f)) => f.into(),
                    (Stdout::Null, None) => Stdio::null(),
                    (Stdout::Capture, None) => Stdio::piped(),
                    (Stdout::Stderr, None) => stderr_handle().map_err(io)?,
                    (_, None) => Stdio::inherit(),
                };
                c.stdout(out).stderr(err);
            }
        }
        let mut child = c.spawn().map_err(io)?;
        // The Command keeps its copy of the pipe's write end: with it open, the read below
        // would never end.
        drop(c);
        if let Some(mut reader) = merged_capture {
            let mut stdout = Vec::new();
            reader.read_to_end(&mut stdout).map_err(io)?;
            let status = child.wait().map_err(io)?;
            return Ok(Outcome {
                code: code_of(status),
                stdout,
                stderr: Vec::new(),
            });
        }
        let output = child.wait_with_output().map_err(io)?;
        Ok(Outcome {
            code: code_of(output.status),
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }

    fn pipe(&self, first: &Cmd, second: &Cmd) -> Result<(Outcome, Outcome)> {
        let io1 = |e: std::io::Error| spawn_error(first, &e);
        let io2 = |e: std::io::Error| spawn_error(second, &e);
        let (reader, writer) = std::io::pipe().map_err(io1)?;
        let mut a = self.command(first);
        a.stdout(writer).stderr(Stdio::inherit());
        let mut child_a = a.spawn().map_err(io1)?;
        // Only the children may hold the write end, or the reader never sees its end.
        drop(a);
        let mut b = self.command(second);
        b.stdin(reader)
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
        let mut child_b = b.spawn().map_err(io2)?;
        drop(b);
        let status_b = child_b.wait().map_err(io2)?;
        let status_a = child_a.wait().map_err(io1)?;
        Ok((
            Outcome {
                code: code_of(status_a),
                ..Outcome::default()
            },
            Outcome {
                code: code_of(status_b),
                ..Outcome::default()
            },
        ))
    }

    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// Up to `attempts` runs, sleeping `delay`, then twice as long, between them. A command
/// whose output goes to a file should append to it, so every attempt stays in the log.
pub fn retry(
    runner: &dyn Runner,
    report: &Reporter,
    attempts: u32,
    delay: Duration,
    cmd: &Cmd,
) -> Result<Outcome> {
    let mut delay = delay;
    let mut n = 1;
    loop {
        let out = runner.run(cmd)?;
        if out.ok() {
            return Ok(out);
        }
        if n >= attempts {
            report.warn(&format!(
                "giving up after {n} attempts (exit {}): {cmd}",
                out.code
            ));
            return Ok(out);
        }
        report.log(&format!(
            "attempt {n}/{attempts} failed (exit {}), retrying in {}s: {cmd}",
            out.code,
            delay.as_secs()
        ));
        runner.sleep(delay);
        n += 1;
        delay *= 2;
    }
}
