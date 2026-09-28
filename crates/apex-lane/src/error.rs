use std::process::ExitCode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exit {
    Ok = 0,
    Error = 1,
    Usage = 2,
    NoShippableBuild = 3,
}

impl From<Exit> for ExitCode {
    fn from(exit: Exit) -> Self {
        Self::from(exit as u8)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LaneError {
    /// Usage or configuration: pkg.env, series, spec-edit, Source1, a dirty checkout.
    #[error("{0}")]
    Usage(String),
    /// Infrastructure: repositories, downloads, signatures, the store; nothing recorded.
    #[error("{0}")]
    Infra(String),
    /// The inputs give no shippable build; the reason was already reported.
    #[error("{0}")]
    NoShippableBuild(String),
}

impl LaneError {
    pub fn exit(&self) -> Exit {
        match self {
            Self::Usage(_) => Exit::Usage,
            Self::Infra(_) => Exit::Error,
            Self::NoShippableBuild(_) => Exit::NoShippableBuild,
        }
    }
}

pub type Result<T, E = LaneError> = std::result::Result<T, E>;

pub fn usage(message: impl Into<String>) -> LaneError {
    LaneError::Usage(message.into())
}

pub fn infra(message: impl Into<String>) -> LaneError {
    LaneError::Infra(message.into())
}

/// A configuration file that the lane refuses (exit 2).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct ConfigError(pub String);

impl From<ConfigError> for LaneError {
    fn from(error: ConfigError) -> Self {
        Self::Usage(error.0)
    }
}
