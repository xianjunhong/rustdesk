#[cfg(windows)]
use hbb_common::config::Config;
use hbb_common::config::LocalConfig;

pub fn read_access_token() -> String {
    #[cfg(windows)]
    {
        read_windows_token().unwrap_or_default()
    }
    #[cfg(not(windows))]
    {
        LocalConfig::get_option_from_file("access_token")
    }
}

pub fn write_access_token(token: &str) -> std::io::Result<()> {
    #[cfg(windows)]
    {
        // The paired sign-in dialog is the only B path that stores a new
        // nonempty token. Refresh reads the token; it never opts in a saved login.
        if crate::dogshare_role::is_receiver() && !token.is_empty() {
            write_voice_consent(token)?;
        }
        write_windows_token(token)?;
        if crate::dogshare_role::is_receiver() && token.is_empty() {
            remove_if_present(&voice_consent_path())?;
        }
        LocalConfig::set_option("access_token".to_owned(), String::new());
    }
    #[cfg(not(windows))]
    LocalConfig::set_option("access_token".to_owned(), token.to_owned());
    Ok(())
}

#[cfg(windows)]
fn token_path() -> std::path::PathBuf {
    Config::path(if crate::dogshare_role::is_split() {
        "DogShare_paired_account.bin"
    } else {
        "DogShare_account.bin"
    })
}

#[cfg(windows)]
const VOICE_CONSENT_HEADER: &[u8] = b"TDVC\x01";
#[cfg(windows)]
const VOICE_CONSENT_ENTROPY: &[u8] = b"DogShare B voice consent v1";

#[cfg(windows)]
fn voice_consent_path() -> std::path::PathBuf {
    Config::path("DogShare_paired_voice_consent.bin")
}

#[cfg(windows)]
fn voice_consent_digest(token: &str) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    Sha256::digest(token.as_bytes()).into()
}

#[cfg(windows)]
fn write_voice_consent(token: &str) -> std::io::Result<()> {
    if token.len() > 4096 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Account credential is too long",
        ));
    }
    let digest = voice_consent_digest(token);
    let encrypted = protect_with_entropy(&digest, true, VOICE_CONSENT_ENTROPY)?;
    write_protected_file(&voice_consent_path(), VOICE_CONSENT_HEADER, &encrypted)
}

#[cfg(windows)]
pub(crate) fn has_voice_consent(token: &str) -> bool {
    use std::io::Read;
    if !crate::dogshare_role::is_receiver() || token.is_empty() {
        return false;
    }
    let Ok(file) = std::fs::File::open(voice_consent_path()) else {
        return false;
    };
    let mut bytes = Vec::new();
    if file.take(4097).read_to_end(&mut bytes).is_err() || bytes.len() > 4096 {
        return false;
    }
    voice_consent_matches(&bytes, token)
}

#[cfg(windows)]
fn voice_consent_matches(bytes: &[u8], token: &str) -> bool {
    let Some(ciphertext) = bytes.strip_prefix(VOICE_CONSENT_HEADER) else {
        return false;
    };
    let Ok(digest) = protect_with_entropy(ciphertext, false, VOICE_CONSENT_ENTROPY) else {
        return false;
    };
    !token.is_empty()
        && hbb_common::sodiumoxide::utils::memcmp(&digest, &voice_consent_digest(token))
}

#[cfg(windows)]
fn read_windows_token() -> std::io::Result<String> {
    let bytes = std::fs::read(token_path())?;
    if bytes.len() > 16384 || !bytes.starts_with(b"TDAC\x01") {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid account credential file",
        ));
    }
    let decrypted = protect(&bytes[5..], false)?;
    String::from_utf8(decrypted).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid account credential encoding",
        )
    })
}

#[cfg(windows)]
fn remove_if_present(path: &std::path::Path) -> std::io::Result<()> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

#[cfg(windows)]
fn write_windows_token(token: &str) -> std::io::Result<()> {
    let path = token_path();
    if token.is_empty() {
        return remove_if_present(&path);
    }
    if token.len() > 4096 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Account credential is too long",
        ));
    }
    let encrypted = protect(token.as_bytes(), true)?;
    write_protected_file(&path, b"TDAC\x01", &encrypted)
}

#[cfg(windows)]
fn write_protected_file(
    path: &std::path::Path,
    header: &[u8],
    ciphertext: &[u8],
) -> std::io::Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(header)?;
        file.write_all(ciphertext)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}

#[cfg(windows)]
fn protect(bytes: &[u8], encrypt: bool) -> std::io::Result<Vec<u8>> {
    protect_with_entropy(bytes, encrypt, b"DogShare account token v1")
}

#[cfg(windows)]
fn protect_with_entropy(bytes: &[u8], encrypt: bool, entropy: &[u8]) -> std::io::Result<Vec<u8>> {
    use std::{ptr, slice};
    use winapi::um::{
        dpapi::{CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN},
        winbase::LocalFree,
        wincrypt::DATA_BLOB,
    };
    let mut input = DATA_BLOB {
        cbData: bytes.len() as u32,
        pbData: bytes.as_ptr() as *mut u8,
    };
    let mut entropy_blob = DATA_BLOB {
        cbData: entropy.len() as u32,
        pbData: entropy.as_ptr() as *mut u8,
    };
    let mut output = DATA_BLOB {
        cbData: 0,
        pbData: ptr::null_mut(),
    };
    // No machine-wide flag: another Windows user or a SYSTEM service cannot use this login.
    let ok = unsafe {
        if encrypt {
            CryptProtectData(
                &mut input,
                ptr::null(),
                &mut entropy_blob,
                ptr::null_mut(),
                ptr::null_mut(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &mut input,
                ptr::null_mut(),
                &mut entropy_blob,
                ptr::null_mut(),
                ptr::null_mut(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        }
    };
    if ok == 0 {
        return Err(std::io::Error::last_os_error());
    }
    if output.pbData.is_null() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid credential protection result",
        ));
    }
    let result = unsafe { slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
    unsafe {
        LocalFree(output.pbData as *mut _);
    }
    Ok(result)
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn voice_consent_is_bound_to_one_token_and_domain() {
        let token = "test-current-b-token";
        let mut marker = VOICE_CONSENT_HEADER.to_vec();
        marker.extend(
            protect_with_entropy(&voice_consent_digest(token), true, VOICE_CONSENT_ENTROPY).unwrap(),
        );
        assert!(voice_consent_matches(&marker, token));
        assert!(!voice_consent_matches(&marker, "test-old-b-token"));
        assert!(!voice_consent_matches(&marker, ""));
        let mut old = b"TDAC\x01".to_vec();
        old.extend(protect(token.as_bytes(), true).unwrap());
        assert!(!voice_consent_matches(&old, token));
        assert!(protect(&marker[VOICE_CONSENT_HEADER.len()..], false).is_err());
        let last = marker.len() - 1;
        marker[last] ^= 1;
        assert!(!voice_consent_matches(&marker, token));
    }

    #[test]
    fn account_credentials_round_trip_and_reject_tampering() {
        let token = b"test-account-token-not-a-real-credential";
        let mut encrypted = protect(token, true).unwrap();
        assert_ne!(encrypted, token);
        assert_eq!(protect(&encrypted, false).unwrap(), token);
        let last = encrypted.len() - 1;
        encrypted[last] ^= 1;
        assert!(protect(&encrypted, false).is_err());
    }
}
