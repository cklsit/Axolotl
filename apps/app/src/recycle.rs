//! Removes a path the launcher reports back to the user as recycled.
//!
//! Desktop platforms hand the path to the operating system recycle bin so an
//! accidental delete stays recoverable. iOS owns the app container and offers
//! no user-visible recycle bin, so the path is removed directly.

#[cfg(not(target_os = "ios"))]
pub fn recycle(path: impl AsRef<std::path::Path>) -> std::io::Result<()> {
    trash::delete(path).map_err(std::io::Error::other)
}

#[cfg(target_os = "ios")]
pub fn recycle(path: impl AsRef<std::path::Path>) -> std::io::Result<()> {
    let path = path.as_ref();
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => std::fs::remove_dir_all(path),
        Ok(_) => std::fs::remove_file(path),
        Err(error) => Err(error),
    }
}
