//! Runs the Minecraft command line inside the application process.
//!
//! iOS refuses to start another executable, so the launcher cannot run the Java
//! command it builds for desktop. The native bridge loads the bundled runtime
//! into this process instead and runs the same command line there.
//!
//! The runtime writes to the process output. The launcher captures that output
//! into its own log for the duration of the game so the log view keeps working
//! the way it does for a child process.

use std::ffi::{CString, c_char, c_int};
use std::io::Read;
use std::os::fd::{FromRawFd, RawFd};
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

    /// Prepares the directory the game loads the launcher executable through.
    fn axolotl_game_prepare(runtime_directory: *const c_char) -> c_int;

    /// Removes the game window and returns the launcher to the screen.
    fn axolotl_game_finish();
}

fn to_cstring(value: &str, what: &str) -> crate::Result<CString> {
    CString::new(value).map_err(|_| {
        crate::ErrorKind::LauncherError(format!(
            "The {what} contains a NUL byte: {value}"
        ))
        .as_error()
    })
}

/// Prepares the directory the game loads the launcher executable through.
///
/// The patched windowing library locates its native side under the bundle path
/// the launcher exports, which has to exist before the runtime starts.
fn prepare_game_window_runtime() -> crate::Result<()> {
    let directory = std::env::temp_dir().join("axolotl-runtime");
    let path = to_cstring(&directory.to_string_lossy(), "runtime directory")?;
    // SAFETY: the pointer refers to a CString that outlives the call, and the
    // bridge only reads it.
    let prepared = unsafe { axolotl_game_prepare(path.as_ptr()) };
    if prepared != 0 {
        return Err(crate::ErrorKind::LauncherError(format!(
            "The game window runtime could not be prepared ({prepared})"
        ))
        .as_error());
    }
    Ok(())
}

/// The process output descriptors the game writes to while it runs.
struct OutputCapture {
    read_fd: RawFd,
    saved_stdout: RawFd,
    saved_stderr: RawFd,
}

impl OutputCapture {
    fn begin() -> std::io::Result<Self> {
        let mut pipe: [RawFd; 2] = [0; 2];
        // SAFETY: pipe fills both entries on success and the result covers the
        // failure case, where neither entry is used.
        if unsafe { libc::pipe(pipe.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        let (read_fd, write_fd) = (pipe[0], pipe[1]);
        // SAFETY: each call duplicates or replaces a valid descriptor; failures
        // surface through the returned value.
        let saved_stdout = unsafe { libc::dup(libc::STDOUT_FILENO) };
        let saved_stderr = unsafe { libc::dup(libc::STDERR_FILENO) };
        if saved_stdout < 0 || saved_stderr < 0 {
            let error = std::io::Error::last_os_error();
            unsafe {
                libc::close(read_fd);
                libc::close(write_fd);
            }
            return Err(error);
        }
        unsafe {
            libc::dup2(write_fd, libc::STDOUT_FILENO);
            libc::dup2(write_fd, libc::STDERR_FILENO);
            libc::close(write_fd);
        }
        Ok(Self {
            read_fd,
            saved_stdout,
            saved_stderr,
        })
    }

    /// Returns the process output to the launcher. The reader owns the read end
    /// and closes it when the last writer goes away.
    fn restore(self) {
        // SAFETY: the saved descriptors stay valid until this restore, which runs
        // once when the runtime returns.
        unsafe {
            libc::dup2(self.saved_stdout, libc::STDOUT_FILENO);
            libc::dup2(self.saved_stderr, libc::STDERR_FILENO);
            libc::close(self.saved_stdout);
            libc::close(self.saved_stderr);
        }
    }
}

/// Copies everything the runtime writes into the launcher log, one line at a
/// time, until the capture is restored and the pipe reports its end.
fn forward_output(read_fd: RawFd) -> std::io::Result<()> {
    // SAFETY: the descriptor is open for reading and this call takes over the
    // only owner of it.
    let mut reader = unsafe { std::fs::File::from_raw_fd(read_fd) };
    let mut buffer = [0_u8; 8192];
    let mut pending = Vec::new();
    loop {
        let read = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) => return Err(error),
        };
        pending.extend_from_slice(&buffer[..read]);
        while let Some(end) = pending.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = pending.drain(..=end).collect();
            log_line(&line[..line.len() - 1]);
        }
    }
    if !pending.is_empty() {
        log_line(&pending);
    }
    Ok(())
}

fn log_line(line: &[u8]) {
    let line = String::from_utf8_lossy(line);
    for line in line.lines() {
        if !line.trim().is_empty() {
            tracing::info!(target: "minecraft", "{line}");
        }
    }
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
    prepare_game_window_runtime()?;

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

    let capture = OutputCapture::begin()?;
    let read_fd = capture.read_fd;
    let reader = std::thread::Builder::new()
        .name("minecraft-output".to_string())
        .spawn(move || forward_output(read_fd))?;

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
            // Restoring the output ends the capture, which lets the reader drain
            // the remaining lines and stop.
            capture.restore();
            // The game window covered the launcher; the session is over.
            // SAFETY: the helper only touches the window it created on the main
            // thread.
            unsafe { axolotl_game_finish() };
            if exit < 0 {
                tracing::error!(
                    exit,
                    "The Java runtime bridge could not start the game"
                );
            } else {
                tracing::info!(exit, "The Java runtime reported the game exit");
            }
            if let Err(error) = reader.join() {
                tracing::warn!(?error, "The game output reader could not finish");
            }
            let _ = sender.send(exit);
        })?;

    Ok(receiver)
}
