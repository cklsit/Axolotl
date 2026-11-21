//! Process-level error dialogs raised before the launcher UI can report a
//! failure, such as an unrecoverable window or webview start-up error.
//!
//! Desktop platforms show a native message box. iOS cannot raise an AppKit
//! dialog and must not block the main thread that hosts the webview, so the
//! failure is written to the launcher log instead, where the diagnostics bundle
//! picks it up.

#[cfg(not(target_os = "ios"))]
pub fn show(title: &str, text: impl Into<String>) {
    native_dialog::DialogBuilder::message()
        .set_level(native_dialog::MessageLevel::Error)
        .set_title(title)
        .set_text(text.into())
        .alert()
        .show()
        .unwrap();
}

#[cfg(target_os = "ios")]
pub fn show(title: &str, text: impl Into<String>) {
    tracing::error!(
        dialog_title = title,
        dialog_text = %text.into(),
        "Launcher reported a start-up failure"
    );
}
