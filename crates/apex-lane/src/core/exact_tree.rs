use std::collections::BTreeSet;

/// Every parent directory of the members and of the moved-to paths, children first.
pub fn prune_dirs(members: &[String], moved_tos: &[String]) -> Vec<String> {
    let mut dirs = BTreeSet::new();
    for m in members.iter().chain(moved_tos) {
        let m = m.strip_suffix('/').unwrap_or(m);
        let Some((mut d, _)) = m.rsplit_once('/') else {
            continue;
        };
        while !d.is_empty() {
            dirs.insert(d.to_owned());
            d = d.rsplit_once('/').map_or("", |(parent, _)| parent);
        }
    }
    dirs.into_iter().rev().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn children_first() {
        let members = [
            "apex.gresource.xml",
            "js/",
            "js/ui/",
            "js/ui/apex/",
            "js/ui/apex/hooks.js",
        ]
        .map(String::from);
        assert_eq!(
            prune_dirs(&members, &["data/theme/apex/stock/x.css".into()]),
            [
                "js/ui/apex",
                "js/ui",
                "js",
                "data/theme/apex/stock",
                "data/theme/apex",
                "data/theme",
                "data"
            ]
        );
    }
}
