#import "AxolotlRuntime.h"

#import <Foundation/Foundation.h>

#include <dlfcn.h>

/// Forwards the launcher's entry points to the game runtime library.
///
/// The game loads that library by name to reach its windowing and graphics
/// symbols, and the library also carries the launch calls. The launcher links
/// this loader instead of the library, so it never hosts the game's symbols and
/// every call travels through the one copy the game loaded.

static const char *kRuntimeName = "GameRuntime/AngelAuraAmethyst";

typedef int (*PrepareFunc)(const char *);
typedef int (*LaunchFunc)(const char *, int, const char **, const char *);
typedef void (*FinishFunc)(void);

static void *axolotl_runtime_library(void) {
    static dispatch_once_t once;
    static void *handle;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:
                [NSString stringWithUTF8String:kRuntimeName]] retain];
        handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (handle == NULL) {
            NSLog(@"[Axolotl] Could not load the game runtime: %s", dlerror());
        }
    });
    return handle;
}

int axolotl_game_prepare(const char *runtime_directory) {
    void *library = axolotl_runtime_library();
    if (library == NULL) {
        return -10;
    }
    PrepareFunc prepare = (PrepareFunc)dlsym(library, "axolotl_game_prepare");
    if (prepare == NULL) {
        NSLog(@"[Axolotl] The game runtime has no prepare entry point");
        return -11;
    }
    return prepare(runtime_directory);
}

int axolotl_launch_jvm(const char *java_home,
                       int argc,
                       const char **argv,
                       const char *working_directory) {
    void *library = axolotl_runtime_library();
    if (library == NULL) {
        return -10;
    }
    LaunchFunc launch = (LaunchFunc)dlsym(library, "axolotl_launch_jvm");
    if (launch == NULL) {
        NSLog(@"[Axolotl] The game runtime has no launch entry point");
        return -11;
    }
    return launch(java_home, argc, argv, working_directory);
}

void axolotl_game_finish(void) {
    void *library = axolotl_runtime_library();
    if (library == NULL) {
        return;
    }
    FinishFunc finish = (FinishFunc)dlsym(library, "axolotl_game_finish");
    if (finish != NULL) {
        finish();
    }
}
