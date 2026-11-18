use std::path::{Path, PathBuf};

/// Look beside the resolved executable first, then beside the reported path.
pub(crate) fn beside_executable(exe: &Path, filename: &str) -> Vec<PathBuf> {
    let mut candidates = Vec::with_capacity(2);
    for path in exe
        .canonicalize()
        .ok()
        .iter()
        .map(PathBuf::as_path)
        .chain([exe])
    {
        if let Some(dir) = path.parent() {
            let candidate = without_verbatim_prefix(dir.join(filename));
            if !candidates.contains(&candidate) {
                candidates.push(candidate);
            }
        }
    }
    candidates
}

fn without_verbatim_prefix(path: PathBuf) -> PathBuf {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::{OsStrExt, OsStringExt};
        use std::path::{Component, Prefix};

        // Windows canonicalization adds a verbatim prefix. Convert drive and
        // UNC paths to their normal forms before deduplication and display.
        if let Some(Component::Prefix(prefix)) = path.components().next() {
            let (skip, mut normal) = match prefix.kind() {
                Prefix::VerbatimDisk(_) => (r"\\?\".len(), Vec::new()),
                Prefix::VerbatimUNC(..) => (r"\\?\UNC\".len(), vec![b'\\' as u16; 2]),
                _ => return path,
            };
            normal.extend(path.as_os_str().encode_wide().skip(skip));
            return PathBuf::from(std::ffi::OsString::from_wide(&normal));
        }
    }
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn beside_executable_deduplicates_and_falls_back_to_the_raw_path() {
        let dir = tempfile::tempdir().unwrap();
        let dir = without_verbatim_prefix(dir.path().canonicalize().unwrap());
        let exe = dir.join("minutes");
        let expected = [dir.join("helper")];

        assert_eq!(beside_executable(&exe, "helper"), expected);
        std::fs::File::create(&exe).unwrap();
        assert_eq!(beside_executable(&exe, "helper"), expected);
    }

    #[cfg(windows)]
    #[test]
    fn strips_verbatim_prefix_from_drive_and_unc_paths() {
        for (verbatim, normal) in [
            (r"\\?\C:\Minutes\helper.exe", r"C:\Minutes\helper.exe"),
            (
                r"\\?\UNC\server\share\helper.exe",
                r"\\server\share\helper.exe",
            ),
        ] {
            assert_eq!(
                without_verbatim_prefix(PathBuf::from(verbatim)).as_os_str(),
                std::ffi::OsStr::new(normal),
            );
        }
    }
}
