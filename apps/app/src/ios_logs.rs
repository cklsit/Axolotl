//! Publishes the launcher log where the platform exposes it to the user.
//!
//! The launcher writes its log inside the application container, which iOS keeps
//! out of reach of the file browser. A copy in the documents directory is
//! readable from Files and from a desktop file browser, which is what a defect
//! report about a device-only failure needs.

use std::io;
use std::path::PathBuf;
use std::time::Duration;

use theseus::prelude::DirectoryInfo;

/// How often the copy is refreshed while the launcher runs.
const MIRROR_INTERVAL: Duration = Duration::from_secs(10);

/// Keeps a readable copy of the launcher log in the documents directory.
pub fn start_mirror(app_identifier: &str) {
    let identifier = app_identifier.to_string();
    let _ = std::thread::Builder::new()
        .name("launcher-log-mirror".to_string())
        .spawn(move || {
            loop {
                if let Err(error) = mirror(&identifier) {
                    tracing::warn!(%error, "Could not publish the launcher log");
                }
                std::thread::sleep(MIRROR_INTERVAL);
            }
        });
}

fn mirror(app_identifier: &str) -> io::Result<()> {
    let Some(source) = DirectoryInfo::launcher_logs_dir_path(app_identifier)
    else {
        return Ok(());
    };
    let target = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Documents").join("logs"))
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "no home directory")
        })?;
    std::fs::create_dir_all(&target)?;
    for entry in std::fs::read_dir(&source)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let name = entry.file_name();
        std::fs::copy(entry.path(), target.join(name))?;
    }
    Ok(())
}
