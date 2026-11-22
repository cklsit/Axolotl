#pragma once

#include <jni.h>

/// Starts the bundled Java runtime in this process and runs the given Java
/// command line.
///
/// - java_home: runtime directory that contains bin/java and lib/libjli.dylib.
/// - argc/argv: the Java command line, argv[0] included. The launcher composes
///   it exactly as it would for a desktop `java` invocation.
/// - working_directory: directory the game runs from, applied before the JVM
///   starts.
///
/// iOS forbids starting another executable, so the runtime is loaded into this
/// process and driven through JLI_Launch. The call blocks until the JVM exits.
///
/// Returns the JLI_Launch exit status, or a negative value when the runtime or
/// its launcher entry point could not be loaded.
int axolotl_launch_jvm(const char *java_home,
                       int argc,
                       const char **argv,
                       const char *working_directory);
