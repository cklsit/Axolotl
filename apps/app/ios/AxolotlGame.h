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

#pragma mark - Input

/// Key actions the game understands, matching the windowing library it uses.
enum {
    AX_KEY_RELEASE = 0,
    AX_KEY_PRESS = 1,
    AX_KEY_REPEAT = 2,
};

/// The keys the on-screen controls drive. The values are the ones the game's
/// windowing library reports, not Unicode code points.
enum {
    AX_KEY_SPACE = 32,
    AX_KEY_A = 65,
    AX_KEY_D = 68,
    AX_KEY_E = 69,
    AX_KEY_Q = 81,
    AX_KEY_S = 83,
    AX_KEY_T = 84,
    AX_KEY_W = 87,
    AX_KEY_ESCAPE = 256,
    AX_KEY_TAB = 258,
    AX_KEY_LEFT_SHIFT = 340,
};

enum {
    AX_MOUSE_LEFT = 0,
    AX_MOUSE_RIGHT = 1,
    AX_MOUSE_MIDDLE = 2,
};

/// Queues a key press or release for the game.
void axolotl_game_post_key(int key, int action);

/// Queues a mouse button press or release for the game.
void axolotl_game_post_mouse(int button, int action);

/// Moves the game cursor by the given amount, which the game reads as looking
/// around while it holds the cursor.
void axolotl_game_move_cursor(double delta_x, double delta_y);

