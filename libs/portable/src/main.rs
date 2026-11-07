#![windows_subsystem = "windows"]

use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use bin_reader::{normalize_path, BinaryReader};

pub mod bin_reader;
#[cfg(windows)]
mod ui;

#[cfg(windows)]
const APP_METADATA: &[u8] = include_bytes!("../app_metadata.toml");
#[cfg(not(windows))]
const APP_METADATA: &[u8] = &[];
const APP_METADATA_CONFIG: &str = "meta.toml";
const META_LINE_PREFIX_TIMESTAMP: &str = "timestamp = ";
const META_LINE_PREFIX_FILE: &str = "file = ";
const APP_PREFIX: &str = "rustdesk";
#[cfg(windows)]
const VERIFIED_UPDATE_FILE_PREFIX: &str = "rustdesk-verified-";
const APPNAME_RUNTIME_ENV_KEY: &str = "RUSTDESK_APPNAME";
#[cfg(windows)]
const SET_FOREGROUND_WINDOW_ENV_KEY: &str = "SET_FOREGROUND_WINDOW";

// The extraction directory follows whatever executable the payload asks for, so a
// custom client gets its own directory instead of sharing RustDesk's. Falls back to
// APP_PREFIX when no package is injected, which keeps stock builds unchanged.
fn app_dir_name(exe: &str) -> String {
    Path::new(&exe.replace('\\', "/"))
        .file_stem()
        .and_then(|stem| stem.to_str())
        .map(|stem| stem.trim().to_lowercase())
        .filter(|stem| !stem.is_empty())
        .unwrap_or_else(|| APP_PREFIX.to_owned())
}

fn is_timestamp_matches(dir: &Path, ts: &mut u64) -> bool {
    let Ok(app_metadata) = std::str::from_utf8(APP_METADATA) else {
        return true;
    };
    for line in app_metadata.lines() {
        if line.starts_with(META_LINE_PREFIX_TIMESTAMP) {
            if let Ok(stored_ts) = line.replace(META_LINE_PREFIX_TIMESTAMP, "").parse::<u64>() {
                *ts = stored_ts;
                break;
            }
        }
    }
    if *ts == 0 {
        return true;
    }

    if let Ok(content) = std::fs::read_to_string(dir.join(APP_METADATA_CONFIG)) {
        for line in content.lines() {
            if line.starts_with(META_LINE_PREFIX_TIMESTAMP) {
                if let Ok(stored_ts) = line.replace(META_LINE_PREFIX_TIMESTAMP, "").parse::<u64>() {
                    return *ts == stored_ts;
                }
            }
        }
    }
    false
}

fn write_meta(dir: &Path, ts: u64, package_paths: &[String]) -> std::io::Result<()> {
    let meta_file = dir.join(APP_METADATA_CONFIG);
    let mut content = format!("{}{}\n", META_LINE_PREFIX_TIMESTAMP, ts);
    for path in package_paths {
        content.push_str(&format!("{}{}\n", META_LINE_PREFIX_FILE, path));
    }
    std::fs::write(meta_file, content)
}

fn previous_package_files(dir: &Path) -> Vec<String> {
    let Ok(content) = std::fs::read_to_string(dir.join(APP_METADATA_CONFIG)) else {
        return Vec::new();
    };
    content
        .lines()
        .filter_map(|line| line.strip_prefix(META_LINE_PREFIX_FILE))
        .map(|path| path.trim().to_owned())
        .collect()
}

// meta.toml is plain text in a user-writable directory, and it now drives deletion,
// so the path is rebuilt from plain components rather than joined as written. A
// prefix, root or parent component would otherwise escape the extraction directory:
// Path::join replaces the base entirely when given an absolute path.
fn resolve_within(dir: &Path, relative: &str) -> Option<PathBuf> {
    use std::path::Component;
    let mut path = dir.to_path_buf();
    let mut any = false;
    for component in Path::new(&relative.replace('\\', "/")).components() {
        match component {
            Component::Normal(part) => {
                // A drive-relative name like "C:x" parses as Normal, and only a
                // Windows host would classify "C:/..." as a Prefix, so the colon is
                // rejected outright rather than relying on the host's parser.
                if part.to_string_lossy().contains(':') {
                    return None;
                }
                path.push(part);
                any = true;
            }
            Component::CurDir => {}
            _ => return None,
        }
    }
    if any {
        Some(path)
    } else {
        None
    }
}

// A customer who drops a branding asset gets a package without it, and the file
// would otherwise linger in an existing extraction and keep being used. The wipe
// cannot cover this: it is keyed on the packer's build timestamp, which is now the
// same for every customer of a release.
fn remove_dropped_package_files_with<F>(
    dir: &Path,
    current: &[String],
    mut remove_file: F,
) -> Vec<String>
where
    F: FnMut(&Path) -> std::io::Result<()>,
{
    let keep: std::collections::HashSet<String> =
        current.iter().map(|p| normalize_path(p)).collect();
    let mut failed = Vec::new();
    for previous in previous_package_files(dir) {
        if keep.contains(&normalize_path(&previous)) {
            continue;
        }
        let Some(path) = resolve_within(dir, &previous) else {
            continue;
        };
        if path.is_file() {
            println!("removing dropped {}", previous);
            if let Err(error) = remove_file(&path) {
                eprintln!("failed to remove dropped {}: {}", previous, error);
                failed.push(previous);
            }
        }
    }
    failed
}

fn remove_dropped_package_files(dir: &Path, current: &[String]) -> Vec<String> {
    remove_dropped_package_files_with(dir, current, |path| std::fs::remove_file(path))
}

#[cfg(windows)]
fn extract_windows_package(
    reader: &BinaryReader,
    dir: &Path,
    clear: bool,
    args: &[String],
    ui: &mut bool,
) -> Result<(), String> {
    let mut ts = 0;
    let refresh = !is_timestamp_matches(dir, &mut ts) || clear;
    let files: Vec<_> = reader
        .files
        .iter()
        .filter(|file| refresh || !file.cached_file_matches(dir))
        .collect();
    if !refresh && files.is_empty() {
        let path_set = |paths: &[String]| {
            paths
                .iter()
                .map(|path| normalize_path(path))
                .collect::<std::collections::HashSet<_>>()
        };
        if path_set(&previous_package_files(dir)) == path_set(&reader.package_paths) {
            return Ok(());
        }
    }

    // A timestamp alone cannot prove that a previous extraction completed.
    // Check the old executable before touching any files from the new package.
    win::check_cached_exe_unlocked(&dir.join(&reader.exe))?;
    if refresh {
        if args.is_empty() {
            *ui = true;
            ui::setup();
        }
        match std::fs::remove_dir_all(dir) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("Could not clear the DogShare cache: {error}")),
        }
    } else if let Some(path) = remove_dropped_package_files(dir, &reader.package_paths).first() {
        return Err(format!("Could not remove the old package file: {path}"));
    }
    for file in files {
        file.extract_to(dir)
            .map_err(|error| format!("Could not extract {}: {error}", file.path))?;
    }
    write_meta(dir, ts, &reader.package_paths)
        .map_err(|error| format!("Could not update the DogShare cache metadata: {error}"))
}

fn setup(
    reader: BinaryReader,
    dir: Option<PathBuf>,
    clear: bool,
    _args: &Vec<String>,
    _ui: &mut bool,
) -> Result<Option<PathBuf>, String> {
    let dir = if let Some(dir) = dir {
        dir
    } else {
        // home dir
        if let Some(dir) = dirs::data_local_dir() {
            dir.join(app_dir_name(&reader.exe))
        } else {
            eprintln!("not found data local dir");
            return Ok(None);
        }
    };

    #[cfg(windows)]
    {
        extract_windows_package(&reader, &dir, clear, _args, _ui)?;
        win::copy_runtime_broker(&dir);
    }
    #[cfg(not(windows))]
    {
        let mut ts = 0;
        if clear || !is_timestamp_matches(&dir, &mut ts) {
            std::fs::remove_dir_all(&dir).ok();
        }
        let mut metadata_paths = reader.package_paths.clone();
        metadata_paths.extend(remove_dropped_package_files(&dir, &reader.package_paths));
        for file in reader.files.iter() {
            file.write_to_file(&dir);
        }
        let _ = write_meta(&dir, ts, &metadata_paths);
        #[cfg(linux)]
        reader.configure_permission(&dir);
    }
    Ok(Some(dir.join(&reader.exe)))
}

fn use_null_stdio() -> bool {
    #[cfg(windows)]
    {
        // When running in CMD on Windows 7, using Stdio::inherit() with spawn returns an "invalid handle" error.
        // Since using Stdio::null() didn’t cause any issues, and determining whether the program is launched from CMD or by double-clicking would require calling more APIs during startup, we also use Stdio::null() when launched by double-clicking on Windows 7.
        let is_windows_7 = is_windows_7();
        println!("is windows7: {}", is_windows_7);
        return is_windows_7;
    }
    #[cfg(not(windows))]
    false
}

#[cfg(windows)]
fn is_windows_7() -> bool {
    use windows::Wdk::System::SystemServices::RtlGetVersion;
    use windows::Win32::System::SystemInformation::OSVERSIONINFOW;

    unsafe {
        let mut version_info = OSVERSIONINFOW::default();
        version_info.dwOSVersionInfoSize = std::mem::size_of::<OSVERSIONINFOW>() as u32;

        if RtlGetVersion(&mut version_info).is_ok() {
            // Windows 7 is version 6.1
            println!(
                "Windows version: {}.{}",
                version_info.dwMajorVersion, version_info.dwMinorVersion
            );
            return version_info.dwMajorVersion == 6 && version_info.dwMinorVersion == 1;
        }
    }
    false
}

fn execute(path: PathBuf, args: Vec<String>, _ui: bool) {
    println!("executing {}", path.display());
    // setup env
    let exe = std::env::current_exe().unwrap_or_default();
    let exe_name = exe.file_name().unwrap_or_default();
    // run executable
    let mut cmd = Command::new(path);
    cmd.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(winapi::um::winbase::CREATE_NO_WINDOW);
        if _ui {
            cmd.env(SET_FOREGROUND_WINDOW_ENV_KEY, "1");
        }
    }

    cmd.env(APPNAME_RUNTIME_ENV_KEY, exe_name);
    if use_null_stdio() {
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
    } else {
        cmd.stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
    }
    let _child = cmd.spawn();

    #[cfg(windows)]
    if _ui {
        match _child {
            Ok(child) => unsafe {
                winapi::um::winuser::AllowSetForegroundWindow(child.id() as u32);
            },
            Err(e) => {
                eprintln!("{:?}", e);
            }
        }
    }
}

fn main() -> Result<(), String> {
    let mut args = Vec::new();
    let mut arg_exe = Default::default();
    let mut i = 0;
    for arg in std::env::args() {
        if i == 0 {
            arg_exe = arg.clone();
        } else {
            args.push(arg);
        }
        i += 1;
    }
    let click_setup = args.is_empty() && arg_exe.to_lowercase().ends_with("install.exe");
    #[cfg(windows)]
    let quick_support = args.is_empty() && win::is_quick_support_exe(&arg_exe);
    #[cfg(not(windows))]
    let quick_support = false;

    #[cfg(windows)]
    if args.first().is_some_and(|arg| arg == "--update") {
        if let Err(err) = win::schedule_verified_update_cleanup() {
            eprintln!("Failed to schedule verified update file cleanup: {}", err);
        }
    }

    let mut ui = false;
    let reader = BinaryReader::new()?;
    let exe = setup(
        reader,
        None,
        click_setup || args.contains(&"--silent-install".to_owned()),
        &args,
        &mut ui,
    );
    #[cfg(windows)]
    if args.is_empty() {
        if let Err(error) = &exe {
            win::show_launch_error(error);
        }
    }
    if let Some(exe) = exe? {
        if click_setup {
            args = vec!["--install".to_owned()];
        } else if quick_support {
            args = vec!["--quick_support".to_owned()];
        }
        execute(exe, args, ui);
    }
    Ok(())
}

#[cfg(windows)]
mod win {
    use std::{
        fs, io,
        os::windows::{fs::OpenOptionsExt, process::CommandExt},
        path::Path,
        process::Command,
    };
    use winapi::shared::winerror::{
        ERROR_LOCK_VIOLATION, ERROR_SHARING_VIOLATION, ERROR_USER_MAPPED_FILE,
    };

    // Used for privacy mode(magnifier impl).
    pub const RUNTIME_BROKER_EXE: &'static str = "C:\\Windows\\System32\\RuntimeBroker.exe";
    pub const WIN_TOPMOST_INJECTED_PROCESS_EXE: &'static str = "RuntimeBroker_rustdesk.exe";

    pub(super) fn check_cached_exe_unlocked(path: &Path) -> Result<(), String> {
        match fs::OpenOptions::new()
            .write(true)
            .share_mode(0)
            .open(path)
        {
            Ok(_) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error)
                if error.raw_os_error().is_some_and(|code| {
                    matches!(
                        code as u32,
                        ERROR_SHARING_VIOLATION | ERROR_LOCK_VIOLATION | ERROR_USER_MAPPED_FILE
                    )
                }) =>
            {
                Err(concat!(
                    "DogShare 仍在运行。请先退出正在运行的 DogShare 程序，再打开此文件。\n\n",
                    "DogShare is still running. Exit the running DogShare program, then open this file again."
                )
                .to_owned())
            }
            Err(error) => Err(format!("Could not access the cached DogShare program: {error}")),
        }
    }

    pub(super) fn show_launch_error(error: &str) {
        use winapi::um::winuser::{MessageBoxW, MB_ICONERROR, MB_OK};

        let message: Vec<_> = error.encode_utf16().chain(std::iter::once(0)).collect();
        let caption: Vec<_> = "DogShare".encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            MessageBoxW(
                std::ptr::null_mut(),
                message.as_ptr(),
                caption.as_ptr(),
                MB_OK | MB_ICONERROR,
            );
        }
    }

    pub(super) fn schedule_verified_update_cleanup() -> std::io::Result<()> {
        use windows::{
            core::{HSTRING, PCWSTR},
            Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_DELAY_UNTIL_REBOOT},
        };

        let current_exe = std::env::current_exe()?;
        let is_verified_update = current_exe
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| {
                name.starts_with(super::VERIFIED_UPDATE_FILE_PREFIX) && name.ends_with(".exe")
            });
        if !is_verified_update {
            return Ok(());
        }

        unsafe {
            MoveFileExW(
                &HSTRING::from(current_exe.as_path()),
                PCWSTR::null(),
                MOVEFILE_DELAY_UNTIL_REBOOT,
            )
        }
        .map_err(std::io::Error::other)
    }

    pub(super) fn copy_runtime_broker(dir: &Path) {
        let src = RUNTIME_BROKER_EXE;
        let tgt = WIN_TOPMOST_INJECTED_PROCESS_EXE;
        let target_file = dir.join(tgt);
        if target_file.exists() {
            if let (Ok(src_file), Ok(tgt_file)) = (fs::read(src), fs::read(&target_file)) {
                let src_md5 = format!("{:x}", md5::compute(&src_file));
                let tgt_md5 = format!("{:x}", md5::compute(&tgt_file));
                if src_md5 == tgt_md5 {
                    return;
                }
            }
        }
        let _allow_err = Command::new("taskkill")
            .args(&["/F", "/IM", "RuntimeBroker_rustdesk.exe"])
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .output();
        let _allow_err = std::fs::copy(src, &format!("{}\\{}", dir.to_string_lossy(), tgt));
    }

    /// Check if the executable is a Quick Support version.
    /// Note: This function must be kept in sync with `src/core_main.rs`.
    #[inline]
    pub(super) fn is_quick_support_exe(exe: &str) -> bool {
        let exe = exe.to_lowercase();
        exe.contains("-qs-") || exe.contains("-qs.exe") || exe.contains("_qs.exe")
    }
}

#[cfg(test)]
mod meta_tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn locked_mixed_cache_is_not_modified_even_if_timestamp_matches() {
        use crate::bin_reader::BinaryData;
        use std::fs;
        use std::io::Write;
        use std::os::windows::fs::OpenOptionsExt;
        use std::time::{SystemTime, UNIX_EPOCH};
        use winapi::um::winnt::FILE_SHARE_READ;

        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                for file in ["TomDesk.exe", "app.so", APP_METADATA_CONFIG] {
                    let _ = fs::remove_file(self.0.join(file));
                }
                let _ = fs::remove_dir(&self.0);
            }
        }

        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "tomdesk-cache-guard-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&dir).unwrap();
        let cleanup = Cleanup(dir);
        let dir = &cleanup.0;
        let exe = dir.join("TomDesk.exe");
        let data = dir.join("app.so");
        fs::write(&exe, b"old executable").unwrap();
        fs::write(&data, b"old application data").unwrap();
        let mut timestamp = 0;
        is_timestamp_matches(dir, &mut timestamp);
        write_meta(dir, timestamp, &[]).unwrap();
        let before = fs::read(dir.join(APP_METADATA_CONFIG)).unwrap();
        assert!(is_timestamp_matches(dir, &mut timestamp));

        let blocker = fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .open(&exe)
            .unwrap();
        let record = |bytes: &[u8]| {
            let digest = format!("{:x}", md5::compute(bytes));
            &*Box::leak(digest.into_bytes().into_boxed_slice()) as &'static [u8]
        };
        let mut reader = BinaryReader {
            exe: "TomDesk.exe".to_owned(),
            files: vec![
                BinaryData {
                    md5_code: record(b"old application data"),
                    raw: b"",
                    path: "app.so".to_owned(),
                },
                BinaryData {
                    md5_code: record(b"old executable"),
                    raw: b"",
                    path: "TomDesk.exe".to_owned(),
                },
            ],
            package_paths: Vec::new(),
        };
        let mut ui = false;
        extract_windows_package(&reader, dir, false, &[], &mut ui).unwrap();
        reader.files[0].md5_code = record(b"new application data");
        reader.files[1].md5_code = record(b"new executable");
        let error = extract_windows_package(&reader, dir, false, &[], &mut ui).unwrap_err();
        assert!(error.contains("still running"));
        assert!(!ui);
        assert_eq!(fs::read(&exe).unwrap(), b"old executable");
        assert_eq!(fs::read(&data).unwrap(), b"old application data");
        assert_eq!(fs::read(dir.join(APP_METADATA_CONFIG)).unwrap(), before);

        drop(blocker);
        let compress = |bytes: &[u8]| {
            let mut encoded = Vec::new();
            {
                let mut writer = brotli::CompressorWriter::new(&mut encoded, 4096, 4, 20);
                writer.write_all(bytes).unwrap();
            }
            &*Box::leak(encoded.into_boxed_slice()) as &'static [u8]
        };
        reader.files[0].raw = compress(b"new application data");
        reader.files[1].raw = compress(b"new executable");
        extract_windows_package(&reader, dir, false, &[], &mut ui).unwrap();
        assert_eq!(fs::read(&exe).unwrap(), b"new executable");
        assert_eq!(fs::read(&data).unwrap(), b"new application data");
        assert!(is_timestamp_matches(dir, &mut timestamp));
        assert!(!ui);
    }

    #[test]
    fn resolve_within_rejects_paths_that_escape() {
        let base = Path::new("/base");
        assert_eq!(
            resolve_within(base, "./data/logo.png"),
            Some(base.join("data").join("logo.png"))
        );
        assert_eq!(
            resolve_within(base, ".\\data\\logo.png"),
            Some(base.join("data").join("logo.png"))
        );
        // meta.toml is user-writable, so these must not reach remove_file.
        assert_eq!(resolve_within(base, "../../etc/passwd"), None);
        assert_eq!(resolve_within(base, "/etc/passwd"), None);
        assert_eq!(resolve_within(base, "C:\\Windows\\System32\\x.dll"), None);
        assert_eq!(resolve_within(base, "."), None);
        assert_eq!(resolve_within(base, ""), None);
    }
}
