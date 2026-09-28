use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct UtcSecond(pub i64);

impl UtcSecond {
    pub fn parse(s: &[u8]) -> Option<Self> {
        let s = std::str::from_utf8(s).ok()?;
        let b = s.as_bytes();
        if b.len() != 20
            || b[4] != b'-'
            || b[7] != b'-'
            || b[10] != b'T'
            || b[13] != b':'
            || b[16] != b':'
            || b[19] != b'Z'
        {
            return None;
        }
        let num = |range: std::ops::Range<usize>| -> Option<i64> {
            let part = &s[range];
            part.bytes()
                .all(|c| c.is_ascii_digit())
                .then(|| part.parse().ok())
                .flatten()
        };
        let (year, month, day) = (num(0..4)?, num(5..7)?, num(8..10)?);
        let (hour, minute, second) = (num(11..13)?, num(14..16)?, num(17..19)?);
        let days_in_month = match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 if is_leap(year) => 29,
            2 => 28,
            _ => return None,
        };
        if day < 1 || day > days_in_month || hour > 23 || minute > 59 || second > 59 {
            return None;
        }
        let days = days_from_civil(year, month, day);
        Some(Self(days * 86_400 + hour * 3600 + minute * 60 + second))
    }

    #[must_use]
    pub fn add_hours(self, hours: i64) -> Self {
        Self(self.0 + hours * 3600)
    }

    #[must_use]
    pub fn add_days(self, days: i64) -> Self {
        Self(self.0 + days * 86_400)
    }
}

impl fmt::Display for UtcSecond {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (days, secs) = (self.0.div_euclid(86_400), self.0.rem_euclid(86_400));
        let (year, month, day) = civil_from_days(days);
        write!(
            f,
            "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
            secs / 3600,
            secs % 3600 / 60,
            secs % 60
        )
    }
}

fn is_leap(year: i64) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

/// Howard Hinnant's `days_from_civil`.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Howard Hinnant's `civil_from_days`.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(s: &str) -> UtcSecond {
        UtcSecond::parse(s.as_bytes()).unwrap()
    }

    #[test]
    fn round_trip_and_arithmetic() {
        assert_eq!(t("1970-01-01T00:00:00Z").0, 0);
        assert_eq!(
            t("2026-10-12T04:10:00Z").to_string(),
            "2026-10-12T04:10:00Z"
        );
        assert_eq!(
            t("2026-10-12T04:10:00Z").add_days(14).to_string(),
            "2026-10-26T04:10:00Z"
        );
        assert_eq!(
            t("2028-02-27T23:00:00Z").add_hours(72).to_string(),
            "2028-03-01T23:00:00Z"
        );
        assert_eq!(
            t("2026-12-25T12:00:00Z").add_days(14).to_string(),
            "2027-01-08T12:00:00Z"
        );
    }

    #[test]
    fn refuses_other_formats() {
        for bad in [
            "2026-10-12 04:10:00Z",
            "2026-10-12T04:10:00",
            "2026-02-30T00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-10-12T24:00:00Z",
            "",
            "+026-10-12T04:10:00Z",
        ] {
            assert_eq!(UtcSecond::parse(bad.as_bytes()), None, "{bad}");
        }
    }
}
