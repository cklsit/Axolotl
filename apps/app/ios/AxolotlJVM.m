#import "AxolotlJVM.h"

#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>

/// The JNI boolean type. Only its width matters for the launcher signature, and
/// naming it here keeps the bridge independent of the JNI headers, which ship
/// with the runtime rather than with the application.
typedef signed char axolotl_jboolean;

/// Launcher entry point exported by libjli.dylib. The signature matches the Java
/// launcher that ships with the iOS OpenJDK builds the game runtime uses.
typedef int JLI_Launch_func(int argc,
                            const char **argv,
                            int jargc,
                            const char **jargv,
                            int appclassc,
                            const char **appclassv,
                            const char *fullversion,
                            const char *dotversion,
                            const char *pname,
                            const char *lname,
                            axolotl_jboolean javaargs,
                            axolotl_jboolean cpwildcard,
                            axolotl_jboolean javaw,
                            int ergo);

/// The iOS runtime keeps Java threads off the main thread; the launcher passes
/// -XstartOnFirstThread for platforms whose windowing system needs it.
static void configure_runtime_environment(NSString *java_home) {
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
    // The GL translation layer the game runtime carries reads these.
    setenv("LIBGL_NOINTOVLHACK", "1", 1);
    setenv("LIBGL_NORMALIZE", "1", 1);
    setenv("JAVA_HOME", java_home.UTF8String, 1);
}

int axolotl_launch_jvm(const char *java_home,
                       int argc,
                       const char **argv,
                       const char *working_directory) {
    @autoreleasepool {
        if (working_directory != NULL && working_directory[0] != '\0') {
            if (chdir(working_directory) != 0) {
                NSLog(@"[Axolotl] Could not enter the game directory: %s",
                      working_directory);
                return -4;
            }
        }

        NSString *runtime_home =
            java_home != NULL && java_home[0] != '\0'
                ? [NSString stringWithUTF8String:java_home]
                : [[NSBundle mainBundle].bundlePath
                      stringByAppendingPathComponent:@"GameRuntime/java_runtimes/jre21"];
        NSString *jli_path =
            [runtime_home stringByAppendingPathComponent:@"lib/libjli.dylib"];

        if (![NSFileManager.defaultManager fileExistsAtPath:jli_path]) {
            NSLog(@"[Axolotl] Java launcher library is missing: %@", jli_path);
            return -1;
        }

        configure_runtime_environment(runtime_home);
        setenv("INTERNAL_JLI_PATH", jli_path.UTF8String, 1);

        void *libjli = dlopen(jli_path.UTF8String, RTLD_GLOBAL);
        if (libjli == NULL) {
            NSLog(@"[Axolotl] Could not load the Java launcher: %s", dlerror());
            return -2;
        }

        JLI_Launch_func *launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
        if (launch == NULL) {
            NSLog(@"[Axolotl] The Java launcher has no JLI_Launch entry point");
            return -3;
        }

        // Crash reporters install handlers the JVM cannot share; restore the
        // defaults so the runtime keeps control of its own faults.
        signal(SIGSEGV, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        signal(SIGILL, SIG_DFL);
        signal(SIGFPE, SIG_DFL);

        NSLog(@"[Axolotl] Starting the Java runtime from %@", runtime_home);
        return launch(argc, argv, 0, NULL, 0, NULL, "21.0.8", "21", "java",
                      "openjdk", 0, 1, 0, 1);
    }
}
