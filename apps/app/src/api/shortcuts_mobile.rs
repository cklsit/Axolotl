//! Instance shortcuts are a desktop integration: each desktop module writes an
//! operating-system shortcut that reopens the launcher for one instance. iOS
//! launches applications from the home screen and exposes no API for an
//! application to add such an entry, so the command reports that the platform
//! cannot create one instead of writing a file the system would ignore.

use crate::api::Result;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Runtime};

pub fn init<R: Runtime>() -> tauri::plugin::TauriPlugin<R> {
    tauri::plugin::Builder::new("shortcuts")
        .invoke_handler(tauri::generate_handler![create_instance_shortcut])
        .build()
}

/// Shortcut icons are cached next to the shortcut a desktop platform creates.
/// No shortcut exists here, so there is no cached icon to refresh.
pub(crate) async fn sync_instance_shortcut_icon<R: Runtime>(
    _app: &AppHandle<R>,
    _instance_id: &str,
    _source_path: Option<&Path>,
    _only_if_exists: bool,
) -> Result<Option<PathBuf>> {
    Ok(None)
}

#[tracing::instrument(skip_all, level = "info")]
#[tauri::command]
pub async fn create_instance_shortcut<R: Runtime>(
    _app: AppHandle<R>,
    _instance_name: String,
    _instance_id: String,
    _output_path: Option<PathBuf>,
    _server: Option<String>,
    _singleplayer_world: Option<String>,
) -> Result<PathBuf> {
    Err(theseus::ErrorKind::OtherError(
        "This platform cannot create desktop shortcuts".to_string(),
    )
    .as_error()
    .into())
}
