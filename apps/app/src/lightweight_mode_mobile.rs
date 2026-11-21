//! Lightweight mode is a desktop tray feature: it destroys the launcher window
//! while Minecraft runs and restores it from the tray menu. iOS suspends the
//! application instead of hiding a window and exposes no tray, so the same
//! command surface keeps the launcher window alive and reports nothing pending.

use serde::Serialize;
use tauri::{AppHandle, Manager};
use theseus::prelude::CommandPayload;

#[derive(Default)]
pub struct LightweightMode;

#[derive(Serialize)]
pub struct PendingCrash {
    pub instance_id: String,
    pub uuid: String,
}

#[derive(Serialize)]
pub struct FrontendReadyPayload {
    pub pending_crashes: Vec<PendingCrash>,
    pub pending_commands: Vec<CommandPayload>,
}

impl LightweightMode {
    pub async fn exit(&self, _app: &AppHandle) -> Result<(), String> {
        Ok(())
    }
}

pub(crate) fn prevent_implicit_tray_exit(
    _app: &AppHandle,
    _code: Option<i32>,
) -> bool {
    false
}

pub fn init(app: &AppHandle) {
    app.manage(LightweightMode);
}

#[tracing::instrument(skip_all, level = "info")]
#[tauri::command]
pub fn lightweight_mode_frontend_ready(
    _app: AppHandle,
    _route: String,
) -> Result<FrontendReadyPayload, String> {
    Ok(FrontendReadyPayload {
        pending_crashes: Vec::new(),
        pending_commands: Vec::new(),
    })
}

#[tracing::instrument(skip_all, level = "info")]
#[tauri::command]
pub fn lightweight_mode_set_route(_app: AppHandle, _route: String) {}

#[tracing::instrument(skip_all, level = "info")]
#[tauri::command]
pub fn lightweight_mode_enter(_app: AppHandle) -> Result<(), String> {
    Ok(())
}
