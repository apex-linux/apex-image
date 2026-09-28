//! `apex-lane`: the rebuild lane (packaging/README.md). Run it in the builder VM through
//! tools/builder-vm/lane.sh, which builds it from the checkout's HEAD.

use std::io::Write as _;
use std::path::PathBuf;
use std::process::ExitCode;

use apex_lane::container::{self, Container, ModeKind, Paths};
use apex_lane::error::{Exit, LaneError, Result, infra, usage};
use apex_lane::shell::bodhi::CurlBodhi;
use apex_lane::shell::clock::SystemClock;
use apex_lane::shell::cmd::StdRunner;
use apex_lane::shell::report::Reporter;
use apex_lane::vm::{self, Settings, Vm, build::exit_of};
use clap::{Args, CommandFactory as _, FromArgMatches as _, Parser, Subcommand};

/// The tree id of crates/apex-lane this binary was built from (lane.sh sets it).
const BUILT_FROM: Option<&str> = option_env!("APEX_LANE_TREE");

#[derive(Debug, Parser)]
#[command(
    name = "apex-lane",
    about = "The rebuild lane: Fedora SRPMs rebuilt with the Apex inputs of packaging/pkgs/<pkg>/, stored by content key and recorded in rpms.lock.next",
    after_help = concat!(
        "Environment: APEX_STORE [~/apex-store], APEX_GA_REACHED (overrides the Containerfile's ",
        "GA_REACHED), APEX_KEEP_WORK=1 (keep the rpmbuild tree in _build/lane/PKG/work), ",
        "APEX_RPM_SIGNING_ENV [~/.config/apex/rpm-signing.env].\n\n",
        "Exit status: 0 built or unchanged; 1 infrastructure error (nothing recorded); ",
        "2 usage or configuration error; 3 no shippable build (held, degraded, or kept stock)."
    )
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Build what changed and record it in rpms.lock.next (PKG, or all).
    Build { pkg: String },
    /// Print the content key (resolves the SRPM and the pin).
    Key { pkg: String },
    /// A git work tree in _build/pkg/PKG/tree: Fedora's %prep of NVR (default: the build
    /// the lane resolves), the series as commits, then Source1 and the %prep changes.
    Prep { pkg: String, nvr: Option<String> },
    /// Write the work tree's commits back to patches/; each NEW name takes one more
    /// commit and joins the series.
    Export { pkg: String, new: Vec<String> },
    /// The families of rpms.lock.next and rpms.lock.
    Status,
    /// rpms.lock.next becomes rpms.lock (after the image gates).
    Promote,
    /// The owner's choice at a hold limit: the next image takes Fedora's build of the
    /// package's family.
    Stock { pkg: String },
    #[command(hide = true)]
    InContainer(InContainer),
}

#[derive(Debug, Args)]
struct InContainer {
    #[command(subcommand)]
    mode: InContainerMode,
}

#[derive(Debug, Args)]
struct Common {
    #[arg(long)]
    repos_base: String,
    #[arg(long, value_parser = clap::value_parser!(u8).range(0..=1))]
    ga_reached: u8,
    #[arg(long, requires = "source1_tree")]
    source1: Option<String>,
    #[arg(long, requires = "source1")]
    source1_tree: Option<String>,
    #[arg(long)]
    github: bool,
}

#[derive(Debug, Subcommand)]
enum InContainerMode {
    Build {
        pkg: String,
        #[arg(long)]
        n: u64,
        #[arg(long)]
        tool: String,
        #[arg(long)]
        locked_evr: Option<String>,
        #[arg(long)]
        keep_work: bool,
        #[command(flatten)]
        common: Common,
    },
    Key {
        pkg: String,
        #[arg(long)]
        n: u64,
        #[arg(long)]
        tool: String,
        #[command(flatten)]
        common: Common,
    },
    Prep {
        pkg: String,
        nvr: Option<String>,
        #[command(flatten)]
        common: Common,
    },
}

fn main() -> ExitCode {
    std::panic::set_hook(Box::new(|info| {
        let _ = writeln!(std::io::stderr(), "apex-lane: internal error: {info}");
        std::process::exit(Exit::Error as i32);
    }));
    let version = format!(
        "{} (tree {})",
        env!("CARGO_PKG_VERSION"),
        BUILT_FROM.unwrap_or("unknown")
    );
    let matches = match Cli::command().version(&*version.leak()).try_get_matches() {
        Ok(m) => m,
        Err(e) => return clap_exit(&e),
    };
    let cli = match Cli::from_arg_matches(&matches) {
        Ok(cli) => cli,
        Err(e) => return clap_exit(&e),
    };
    let mut report = Reporter::from_env();
    if let Command::InContainer(c) = &cli.command {
        let common = match &c.mode {
            InContainerMode::Build { common, .. }
            | InContainerMode::Key { common, .. }
            | InContainerMode::Prep { common, .. } => common,
        };
        report.github = common.github;
    }
    match run(cli.command, &report) {
        Ok(exit) => exit.into(),
        Err(e) => {
            match &e {
                LaneError::Usage(m) => report.usage_error(m),
                LaneError::Infra(m) => report.error(m),
                LaneError::NoShippableBuild(_) => {}
            }
            e.exit().into()
        }
    }
}

fn clap_exit(e: &clap::Error) -> ExitCode {
    let _ = e.print();
    if e.use_stderr() {
        Exit::Usage.into()
    } else {
        Exit::Ok.into()
    }
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from)
}

fn settings() -> Result<Settings> {
    let env = |name: &str| {
        std::env::var_os(name)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    };
    Ok(Settings {
        store: env("APEX_STORE").unwrap_or_else(|| home().join("apex-store")),
        ga_override: std::env::var("APEX_GA_REACHED")
            .ok()
            .filter(|v| !v.is_empty()),
        keep_work: std::env::var("APEX_KEEP_WORK").is_ok_and(|v| v == "1"),
        signing_env: env("APEX_RPM_SIGNING_ENV")
            .unwrap_or_else(|| home().join(".config/apex/rpm-signing.env")),
        exe: std::env::current_exe()
            .map_err(|e| infra(format!("cannot find this program: {e}")))?,
        uid: nix::unistd::getuid().as_raw(),
        gid: nix::unistd::getgid().as_raw(),
        is_root: nix::unistd::geteuid().is_root(),
    })
}

fn run(command: Command, report: &Reporter) -> Result<Exit> {
    if let Command::InContainer(c) = command {
        return in_container(c, report);
    }
    let cwd = std::env::current_dir().map_err(|e| infra(format!("no working directory: {e}")))?;
    let root = vm::find_root(&cwd).ok_or_else(|| {
        usage(format!(
            "{} is not inside an apex-fedora checkout (packaging/pkgs, image/Containerfile)",
            cwd.display()
        ))
    })?;
    let runner = StdRunner::cleared(&home());
    let vm = Vm {
        root,
        settings: settings()?,
        runner: &runner,
        clock: &SystemClock,
        bodhi: &CurlBodhi { runner: &runner },
        report,
    };
    if matches!(
        command,
        Command::Build { .. } | Command::Key { .. } | Command::Prep { .. }
    ) {
        check_built_from(&vm)?;
    }
    match command {
        Command::Build { pkg } => vm.build(&pkg).map(|outcomes| exit_of(&outcomes)),
        Command::Key { pkg } => vm.key(&pkg),
        Command::Prep { pkg, nvr } => vm.prep(&pkg, nvr.as_deref()),
        Command::Export { pkg, new } => vm.export(&pkg, &new).map(|()| Exit::Ok),
        Command::Status => {
            let text = vm.status()?;
            let mut out = std::io::stdout().lock();
            match out.write_all(&text).and_then(|()| out.flush()) {
                Err(e) if e.kind() != std::io::ErrorKind::BrokenPipe => {
                    Err(infra(format!("cannot write to stdout: {e}")))
                }
                _ => Ok(Exit::Ok),
            }
        }
        Command::Promote => vm.promote().map(|()| Exit::Ok),
        Command::Stock { pkg } => vm.stock(&pkg).map(|()| Exit::Ok),
        Command::InContainer(_) => unreachable!("handled above"),
    }
}

/// build, key and prep run the Fedora half with this binary: it must be the lane of the
/// checkout's HEAD, whose tree also goes into the content key.
fn check_built_from(vm: &Vm<'_>) -> Result<()> {
    let head = vm.head_lane_tree()?;
    match (BUILT_FROM, head.as_deref()) {
        (Some(built), Some(head)) if built == head => Ok(()),
        (built, head) => Err(usage(format!(
            "this apex-lane was built from tree {}, but the checkout's HEAD has {} at {}; run it through tools/builder-vm/lane.sh",
            built.unwrap_or("unknown"),
            head.unwrap_or("nothing"),
            vm::LANE_TREE_PATH
        ))),
    }
}

fn in_container(c: InContainer, report: &Reporter) -> Result<Exit> {
    let (mode, pkg, nvr, n, tool, locked_evr, keep_work, common) = match c.mode {
        InContainerMode::Build {
            pkg,
            n,
            tool,
            locked_evr,
            keep_work,
            common,
        } => (
            ModeKind::Build,
            pkg,
            None,
            n,
            tool,
            locked_evr,
            keep_work,
            common,
        ),
        InContainerMode::Key {
            pkg,
            n,
            tool,
            common,
        } => (ModeKind::Key, pkg, None, n, tool, None, false, common),
        InContainerMode::Prep { pkg, nvr, common } => (
            ModeKind::Prep,
            pkg,
            nvr,
            0,
            String::new(),
            None,
            false,
            common,
        ),
    };
    let runner = StdRunner::inherit();
    let container = Container {
        paths: Paths::default(),
        args: container::Args {
            mode,
            pkg,
            nvr,
            n,
            tool,
            repos_base: common.repos_base,
            ga_reached: common.ga_reached,
            source1: common.source1,
            source1_tree: common.source1_tree,
            locked_evr,
            keep_work,
        },
        runner: &runner,
        report,
        is_root: nix::unistd::geteuid().is_root(),
    };
    container.run().map(|()| Exit::Ok)
}
