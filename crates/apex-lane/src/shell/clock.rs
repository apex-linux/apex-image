use std::time::{SystemTime, UNIX_EPOCH};

use crate::core::utc::UtcSecond;

pub trait Clock {
    fn now(&self) -> UtcSecond;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> UtcSecond {
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        UtcSecond(i64::try_from(secs).unwrap_or(i64::MAX))
    }
}

#[derive(Debug, Clone, Copy)]
pub struct FixedClock(pub UtcSecond);

impl Clock for FixedClock {
    fn now(&self) -> UtcSecond {
        self.0
    }
}
