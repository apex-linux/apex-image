/// Source1's member `m` is allowed by the `source1_paths` entries: a file, or a directory
/// when it ends in `/`. A directory member is also allowed when it is a parent of an entry.
pub fn member_ok(m: &str, paths: &[String]) -> bool {
    paths.iter().any(|p| {
        let parent_of_entry = m.ends_with('/') && p.starts_with(m);
        if p.ends_with('/') {
            m.starts_with(p.as_str()) || parent_of_entry
        } else {
            m == p || parent_of_entry
        }
    })
}

/// `apex-<basename>-<tree[0:12]>.tar`.
pub fn archive_name(source1: &str, tree: &str) -> String {
    let base = source1.rsplit('/').next().unwrap_or(source1);
    let short: String = tree.chars().take(12).collect();
    format!("apex-{base}-{short}.tar")
}
