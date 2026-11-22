#pragma once

/// Entry points the launcher process calls into for the game runtime.
///
/// The game resolves its windowing and graphics symbols from a library it loads
/// by name, so everything that serves the game is built into that library and
/// this header names the small surface the launcher itself uses.
///
/// All three functions are provided twice: once by the game runtime library and
/// once by the loader that the launcher links, which forwards to the library.

/// Prepares the process and the directory the game loads the library through.
int axolotl_game_prepare(const char *runtime_directory);

/// Starts the bundled Java runtime with the given command line and blocks until
/// it exits. Negative results report a runtime that could not load.
int axolotl_launch_jvm(const char *java_home,
                       int argc,
                       const char **argv,
                       const char *working_directory);

/// Removes the game window and returns the launcher to the screen.
void axolotl_game_finish(void);
