#pragma once

/// Prepares the process for a game launch.
///
/// The patched windowing library the game loads expects to find it under the
/// launcher executable. iOS cannot start another process, so the launcher makes
/// the game's window and graphics context part of this process instead.
///
/// The helper creates the directory the library loads the executable through and
/// exports it as the bundle path. Returns 0 on success.
int axolotl_game_prepare(const char *runtime_directory);
