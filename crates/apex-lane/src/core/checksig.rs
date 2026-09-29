use crate::core::text;

const SIGNATURE_KEY: &[u8] = b"signature, key";

/// `key_id`, a fingerprint tail, matches rpm 4's `Signature, key ID f577861e: OK` by its last 8
/// hex digits, and rpm 6's `signature, key fingerprint: 4f50...861e: OK` also when whole.
pub fn checksig_ok(output: &[u8], key_id: &str) -> bool {
    let id = key_id.to_ascii_lowercase();
    let mut any = false;
    let mut signed = false;
    for line in text::newline_terminated_lines(output) {
        let lower = line.to_ascii_lowercase();
        if !text::contains(&lower, b"signature") {
            continue;
        }
        any = true;
        if !line.ends_with(b": OK") {
            return false;
        }
        if let Some(at) = text::find(&lower, SIGNATURE_KEY)
            && text::contains(&lower[at + SIGNATURE_KEY.len()..], id.as_bytes())
        {
            signed = true;
        }
    }
    any && signed
}
