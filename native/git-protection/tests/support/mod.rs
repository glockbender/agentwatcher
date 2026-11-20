use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(0);

pub struct TestDirectory(PathBuf);

impl TestDirectory {
    pub fn new(label: &str) -> Self {
        loop {
            let number = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "mothership-{label}-{}-{number}",
                std::process::id()
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => return Self(path),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => panic!("test directory: {error}"),
            }
        }
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        if std::env::var_os("MOTHERSHIP_KEEP_TEST_DIRS").as_deref()
            == Some(std::ffi::OsStr::new("1"))
        {
            return;
        }
        // Preserve Finder recovery; never recursively delete a test directory.
        let _ = Command::new(if cfg!(target_os = "macos") {
            "/usr/bin/trash"
        } else {
            "trash"
        })
        .arg(&self.0)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    }
}
