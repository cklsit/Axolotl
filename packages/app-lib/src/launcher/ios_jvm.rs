//! Runs the Minecraft command line inside the application process.
//!
//! iOS refuses to start another executable, so the launcher cannot run the Java
//! command it builds for desktop. The native bridge loads the bundled runtime
//! into this process instead and runs the same command line there.
//!
//! The runtime prints to the process console; the launcher keeps the command
//! line, the working directory and the exit status it reports.

use std::ffi::{CString, c_char, c_int};
use std::path::Path;

unsafe extern "C" {
    /// Starts the bundled runtime and runs the command line. Blocks until the
    /// runtime exits; negative results report a runtime that could not load.
    fn axolotl_launch_jvm(
        java_home: *const c_char,
        argc: c_int,
        argv: *const *const c_char,
        working_directory: *const c_char,
    ) -> c_int;
}

fn to_cstring(value: &str, what: &str) -> crate::Result<CString> {
    CString::new(value).map_err(|_| {
        crate::ErrorKind::LauncherError(format!(
            "The {what} contains a NUL byte: {value}"
        ))
        .as_error()
    })
}

/// Starts the game and returns a receiver that carries its exit status.
///
/// The runtime runs on its own thread because the Java launcher blocks for the
/// whole session and needs a stack the caller does not have to reserve.
pub fn start(
    java_home: &Path,
    program: &Path,
    arguments: &[String],
    environment: &[(String, String)],
    working_directory: &Path,
) -> crate::Result<tokio::sync::oneshot::Receiver<i32>> {
    let home = to_cstring(&java_home.to_string_lossy(), "Java runtime path")?;
    let directory =
        to_cstring(&working_directory.to_string_lossy(), "game directory")?;

    let mut argv = Vec::with_capacity(arguments.len() + 1);
    argv.push(to_cstring(&program.to_string_lossy(), "Java executable")?);
    for argument in arguments {
        argv.push(to_cstring(argument, "Java argument")?);
    }

    // The command already carries the environment the game runs with. Applying
    // it here keeps the runtime and the launcher on the same process-wide view.
    for (key, value) in environment {
        // SAFETY: launch starts one game per process, and no other thread reads
        // the environment while the launcher prepares it.
        unsafe { std::env::set_var(key, value) };
    }

    let (sender, receiver) = tokio::sync::oneshot::channel();
    std::thread::Builder::new()
        .name("minecraft-runtime".to_string())
        .stack_size(16 * 1024 * 1024)
        .spawn(move || {
            // The argument pointers are built on this thread because a raw
            // pointer cannot cross the thread boundary on its own.
            let pointers: Vec<*const c_char> =
                argv.iter().map(|value| value.as_ptr()).collect();
            // SAFETY: every pointer refers to a CString `argv` owns for the whole
            // call, and the bridge only reads them.
            let exit = unsafe {
                axolotl_launch_jvm(
                    home.as_ptr(),
                    pointers.len() as c_int,
                    pointers.as_ptr(),
                    directory.as_ptr(),
                )
            };
            if exit < 0 {
                tracing::error!(
                    exit,
                    "The Java runtime bridge could not start the game"
                );
            } else {
                tracing::info!(exit, "The Java runtime reported the game exit");
            }
            let _ = sender.send(exit);
        })?;

    Ok(receiver)
}
