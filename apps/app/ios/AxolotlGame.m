#import "AxolotlGame.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

/// The game resolves its windowing and graphics entry points from this image by
/// name, so every function it looks for has to stay visible even though the
/// application itself builds with hidden visibility.
#define AX_PUBLIC __attribute__((visibility("default")))

#pragma mark - Diagnostics

/// Records a step of the graphics bring-up where a device report can find it.
///
/// The console a device keeps is out of reach of a file browser, and a failed
/// context leaves nothing in the launcher log, so the steps land in a file the
/// documents directory exposes.
static void ax_log(NSString *message) {
    static dispatch_once_t once;
    static NSDateFormatter *formatter;
    static NSString *path;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        path = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Documents/graphics.log"];
    });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                                                [formatter stringFromDate:[NSDate date]],
                                                message];
    NSLog(@"[Axolotl] %@", message);
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

#pragma mark - EGL

/// The graphics translation layer exposes the EGL entry points the game asks
/// for. They are resolved once and never unloaded while the game runs.
typedef void *AXDisplay;
typedef void *AXConfig;
typedef void *AXContext;
typedef void *AXSurface;
typedef unsigned int AXBoolean;

typedef AXDisplay (*AXGetDisplay)(void *display_id);
typedef AXBoolean (*AXInitialize)(AXDisplay display, int *major, int *minor);
typedef AXBoolean (*AXChooseConfig)(AXDisplay display,
                                    const int *attributes,
                                    AXConfig *configs,
                                    int config_size,
                                    int *count);
typedef AXSurface (*AXCreateWindowSurface)(AXDisplay display,
                                           AXConfig config,
                                           void *window,
                                           const int *attributes);
typedef AXContext (*AXCreateContext)(AXDisplay display,
                                     AXConfig config,
                                     AXContext share,
                                     const int *attributes);
typedef AXBoolean (*AXMakeCurrent)(AXDisplay display,
                                   AXSurface draw,
                                   AXSurface read,
                                   AXContext context);
typedef AXBoolean (*AXSwapBuffers)(AXDisplay display, AXSurface surface);
typedef AXBoolean (*AXBindAPI)(unsigned int api);
typedef int (*AXSwapInterval)(AXDisplay display, int interval);
typedef AXBoolean (*AXDestroyContext)(AXDisplay display, AXContext context);
typedef AXBoolean (*AXDestroySurface)(AXDisplay display, AXSurface surface);
typedef AXBoolean (*AXTerminate)(AXDisplay display);
typedef AXContext (*AXGetCurrentContext)(void);

typedef struct {
    AXGetDisplay eglGetDisplay;
    AXInitialize eglInitialize;
    AXChooseConfig eglChooseConfig;
    AXCreateWindowSurface eglCreateWindowSurface;
    AXCreateContext eglCreateContext;
    AXMakeCurrent eglMakeCurrent;
    AXSwapBuffers eglSwapBuffers;
    AXBindAPI eglBindAPI;
    AXSwapInterval eglSwapInterval;
    AXDestroyContext eglDestroyContext;
    AXDestroySurface eglDestroySurface;
    AXTerminate eglTerminate;
    AXGetCurrentContext eglGetCurrentContext;
} AXEgl;

enum {
    AX_EGL_ALPHA_SIZE = 0x3021,
    AX_EGL_BLUE_SIZE = 0x3022,
    AX_EGL_GREEN_SIZE = 0x3023,
    AX_EGL_RED_SIZE = 0x3024,
    AX_EGL_DEPTH_SIZE = 0x3025,
    AX_EGL_SURFACE_TYPE = 0x3033,
    AX_EGL_NONE = 0x3038,
    AX_EGL_RENDERABLE_TYPE = 0x3040,
    AX_EGL_CONTEXT_CLIENT_VERSION = 0x3098,
    AX_EGL_WINDOW_BIT = 0x0004,
    AX_EGL_PBUFFER_BIT = 0x0001,
    AX_EGL_OPENGL_BIT = 0x0008,
    AX_EGL_OPENGL_ES_API = 0x30A0,
    AX_EGL_OPENGL_API = 0x30A2,
    AX_EGL_OPENGL_ES3_BIT = 0x0040,
};

static AXEgl g_egl;
static AXDisplay g_display;
static BOOL g_egl_ready;
static BOOL g_initialized;

#pragma mark - Game window

/// Hosts the metal layer the graphics context draws into.
@interface AxolotlGameView : UIView
@end

@implementation AxolotlGameView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

@end

static UIWindow *g_game_window;
static AxolotlGameView *g_game_view;

/// Overlay carrying the on-screen controls, above the drawing surface.
UIView *axolotl_controls_view(CGRect bounds);

/// A context bundle owns one surface and one context; the game identifies the
/// window it draws to by this pointer.
typedef struct {
    AXConfig config;
    AXContext context;
    AXSurface surface;
} AXRenderWindow;

static __thread AXRenderWindow *g_current_window;

static void axolotl_show_game_window(void) {
    if (g_game_window != nil) {
        return;
    }
    dispatch_block_t create = ^{
        UIWindow *window =
            [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        // A window created outside the scene hierarchy never becomes visible, so
        // it joins the scene the launcher itself is presented in.
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState ==
                    UISceneActivationStateForegroundActive) {
                window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
                window.frame = [UIScreen mainScreen].bounds;
                break;
            }
        }
        window.windowLevel = UIWindowLevelNormal;
        UIViewController *controller = [[UIViewController alloc] init];
        controller.view.backgroundColor = [UIColor blackColor];
        AxolotlGameView *view =
            [[AxolotlGameView alloc] initWithFrame:window.bounds];
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
        [controller.view addSubview:view];
        UIView *controls = axolotl_controls_view(window.bounds);
        controls.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
        [controller.view addSubview:controls];
        window.rootViewController = controller;
        window.hidden = NO;
        [window makeKeyAndVisible];
        g_game_window = window;
        g_game_view = view;
    };
    if ([NSThread isMainThread]) {
        create();
    } else {
        dispatch_sync(dispatch_get_main_queue(), create);
    }
}

#pragma mark - EGL setup

static void *axolotl_egl_library(void) {
    NSString *runtime = [[NSBundle mainBundle].bundlePath
        stringByAppendingPathComponent:@"GameRuntime"];
    // The desktop entry point bridge re-exports the translation layer's EGL
    // interface, so loading it brings both into the process. Its own dependency
    // supplies the EGL symbols when it is present.
    NSString *bridge = [runtime
        stringByAppendingPathComponent:@"natives/libtinygl4angle.dylib"];
    if ([NSFileManager.defaultManager fileExistsAtPath:bridge]) {
        void *handle = dlopen(bridge.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (handle != NULL) {
            return handle;
        }
        ax_log([NSString stringWithFormat:@"Could not load the desktop GL bridge: %s", dlerror()]);
    }
    NSString *frameworks =
        [runtime stringByAppendingPathComponent:@"Frameworks"];
    NSString *path =
        [frameworks stringByAppendingPathComponent:@"libEGL.framework/libEGL"];
    void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (handle == NULL) {
        ax_log([NSString
            stringWithFormat:@"Could not load the graphics translation layer: %s",
                             dlerror()]);
    }
    return handle;
}

static BOOL axolotl_egl_load(void) {
    if (g_egl_ready) {
        return YES;
    }
    void *handle = axolotl_egl_library();
    if (handle == NULL) {
        return NO;
    }
    g_egl.eglGetDisplay = (AXGetDisplay)dlsym(handle, "eglGetDisplay");
    g_egl.eglInitialize = (AXInitialize)dlsym(handle, "eglInitialize");
    g_egl.eglChooseConfig = (AXChooseConfig)dlsym(handle, "eglChooseConfig");
    g_egl.eglCreateWindowSurface =
        (AXCreateWindowSurface)dlsym(handle, "eglCreateWindowSurface");
    g_egl.eglCreateContext =
        (AXCreateContext)dlsym(handle, "eglCreateContext");
    g_egl.eglMakeCurrent = (AXMakeCurrent)dlsym(handle, "eglMakeCurrent");
    g_egl.eglSwapBuffers = (AXSwapBuffers)dlsym(handle, "eglSwapBuffers");
    g_egl.eglBindAPI = (AXBindAPI)dlsym(handle, "eglBindAPI");
    g_egl.eglSwapInterval = (AXSwapInterval)dlsym(handle, "eglSwapInterval");
    g_egl.eglDestroyContext =
        (AXDestroyContext)dlsym(handle, "eglDestroyContext");
    g_egl.eglDestroySurface =
        (AXDestroySurface)dlsym(handle, "eglDestroySurface");
    g_egl.eglTerminate = (AXTerminate)dlsym(handle, "eglTerminate");
    g_egl.eglGetCurrentContext =
        (AXGetCurrentContext)dlsym(handle, "eglGetCurrentContext");
    if (g_egl.eglInitialize == NULL || g_egl.eglCreateContext == NULL) {
        ax_log(@"The graphics translation layer misses EGL entry points");
        return NO;
    }
    g_egl_ready = YES;
    ax_log(@"Loaded the graphics translation layer");
    return YES;
}

static BOOL axolotl_egl_initialize(void) {
    if (g_display != NULL) {
        return YES;
    }
    if (!axolotl_egl_load()) {
        return NO;
    }
    g_display = g_egl.eglGetDisplay(NULL);
    if (g_display == NULL) {
        ax_log(@"No EGL display is available");
        return NO;
    }
    int major = 0;
    int minor = 0;
    if (!g_egl.eglInitialize(g_display, &major, &minor)) {
        ax_log(@"EGL could not initialize");
        g_display = NULL;
        return NO;
    }
    ax_log([NSString stringWithFormat:@"EGL display ready (%d.%d)", major, minor]);
    return YES;
}

#pragma mark - Windowing entry points

/// The window the game draws to, kept for the input it registers.
static intptr_t g_showing_window;

/// Hands the queued input events to the callbacks the game registered.
static void axolotl_input_pump(void);

/// Returns non-zero when the window system is ready for the game.
AX_PUBLIC int pojavInit(int useStackQueue) {
    (void)useStackQueue;
    ax_log(@"The game asked for a window system");
    g_initialized = axolotl_egl_initialize();
    if (!g_initialized) {
        ax_log(@"The window system could not start");
    }
    return g_initialized ? 1 : 0;
}

AX_PUBLIC void pojavSetWindowHint(int hint, int value) {
    // GLFW_FRAMEBUFFER_SRGB is not part of the hints the launcher acts on.
    (void)hint;
    (void)value;
}

/// Creates the surface and context the game draws with and returns the window
/// the game uses to refer to them.
AX_PUBLIC intptr_t pojavCreateContext(intptr_t share) {
    if (!g_initialized && !axolotl_egl_initialize()) {
        return 0;
    }
    axolotl_show_game_window();

    AXRenderWindow *window = calloc(1, sizeof(AXRenderWindow));
    if (window == NULL) {
        return 0;
    }

    // Versions that ask for a core profile reach the desktop entry points, which
    // are served by binding the desktop API; the GL to GLES layer takes the ES
    // API instead.
    const char *desktop_setting = getenv("AXOLOTL_DESKTOP_GL");
    BOOL desktop_gl =
        desktop_setting != NULL && desktop_setting[0] == '1';
    const int config_attributes[] = {
        AX_EGL_RED_SIZE, 8,   AX_EGL_GREEN_SIZE, 8, AX_EGL_BLUE_SIZE, 8,
        AX_EGL_ALPHA_SIZE, 8, AX_EGL_DEPTH_SIZE, 24,
        AX_EGL_SURFACE_TYPE, AX_EGL_WINDOW_BIT | AX_EGL_PBUFFER_BIT,
        AX_EGL_RENDERABLE_TYPE,
        desktop_gl ? AX_EGL_OPENGL_BIT : AX_EGL_OPENGL_ES3_BIT,
        AX_EGL_NONE,
    };
    int config_count = 0;
    if (!g_egl.eglChooseConfig(g_display, config_attributes, &window->config, 1,
                               &config_count) ||
        config_count < 1) {
        ax_log(@"No graphics configuration matches the game");
        free(window);
        return 0;
    }

    g_egl.eglBindAPI(desktop_gl ? AX_EGL_OPENGL_API : AX_EGL_OPENGL_ES_API);
    ax_log([NSString stringWithFormat:@"Chose a %@ graphics configuration",
                                      desktop_gl ? @"desktop OpenGL" : @"OpenGL ES"]);

    dispatch_sync(dispatch_get_main_queue(), ^{
        g_game_view.frame = g_game_window.bounds;
        CAMetalLayer *layer = (CAMetalLayer *)g_game_view.layer;
        // The drawing surface covers the screen at the display's own scale; the
        // game scales its own framebuffer onto it.
        CGFloat scale = UIScreen.mainScreen.scale;
        CGSize size = g_game_view.bounds.size;
        layer.contentsScale = scale;
        layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
    });

    window->surface = g_egl.eglCreateWindowSurface(
        g_display, window->config, (__bridge void *)g_game_view.layer, NULL);
    if (window->surface == NULL) {
        ax_log(@"The game surface could not be created");
        free(window);
        return 0;
    }
    ax_log(@"Created the game surface");

    const int context_attributes[] = {
        AX_EGL_CONTEXT_CLIENT_VERSION, 3, AX_EGL_NONE,
    };
    AXContext share_context = (AXContext)share;
    window->context = g_egl.eglCreateContext(g_display, window->config,
                                             share_context, context_attributes);
    if (window->context == NULL) {
        ax_log(@"The game context could not be created");
        g_egl.eglDestroySurface(g_display, window->surface);
        free(window);
        return 0;
    }

    g_showing_window = (intptr_t)window;
    ax_log(@"Created the game context");
    return (intptr_t)window;
}

AX_PUBLIC intptr_t pojavGetCurrentContext(void) {
    return (intptr_t)g_current_window;
}

AX_PUBLIC void pojavMakeCurrent(intptr_t window) {
    AXRenderWindow *render = (AXRenderWindow *)window;
    if (render == NULL) {
        return;
    }
    if (g_egl.eglMakeCurrent(g_display, render->surface, render->surface,
                             render->context)) {
        g_current_window = render;
        ax_log(@"Made the game context current");
    } else {
        ax_log(@"The game context could not become current");
    }
}

AX_PUBLIC void pojavSwapBuffers(intptr_t window) {
    AXRenderWindow *render = (AXRenderWindow *)window;
    if (render == NULL || render->surface == NULL) {
        return;
    }
    g_egl.eglSwapBuffers(g_display, render->surface);
}

AX_PUBLIC void pojavSwapInterval(int interval) {
    if (g_display != NULL) {
        g_egl.eglSwapInterval(g_display, interval);
    }
}

AX_PUBLIC void pojavPumpEvents(intptr_t window) {
    g_showing_window = window;
    axolotl_input_pump();
}

AX_PUBLIC void pojavRewindEvents(void) {}

AX_PUBLIC void pojavDetachOnCurrentThread(void) {}

AX_PUBLIC void pojavTerminate(void) {
    if (g_current_window != NULL) {
        g_egl.eglMakeCurrent(g_display, NULL, NULL, NULL);
        g_current_window = NULL;
    }
    if (g_display != NULL) {
        g_egl.eglTerminate(g_display);
        g_display = NULL;
    }
    g_initialized = NO;
}

#pragma mark - Input callbacks

/// The patched windowing library registers its event callbacks through native
/// methods. They are kept here so the launcher can deliver input events to the
/// game exactly where the desktop window system would.
typedef struct {
    intptr_t character;
    intptr_t character_mods;
    intptr_t cursor_enter;
    intptr_t cursor_position;
    intptr_t framebuffer_size;
    intptr_t key;
    intptr_t mouse_button;
    intptr_t scroll;
    intptr_t window_size;
} AXCallbacks;

static AXCallbacks g_callbacks;

#pragma mark - Input queue

typedef struct {
    int type;
    int i1;
    int i2;
    int i3;
    int i4;
    double f1;
    double f2;
} AXInputEvent;

enum {
    AX_EVENT_CURSOR_POS = 1003,
    AX_EVENT_KEY = 1005,
    AX_EVENT_MOUSE_BUTTON = 1006,
    AX_EVENT_SCROLL = 1007,
};

static AXInputEvent g_events[512];
static int g_event_count;
static NSLock *g_event_lock;
static double g_cursor_x = 512;
static double g_cursor_y = 384;

static void axolotl_input_push(AXInputEvent event) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
        g_event_lock = lock;
    });
    [lock lock];
    if (g_event_count < (int)(sizeof(g_events) / sizeof(g_events[0]))) {
        g_events[g_event_count++] = event;
    }
    [lock unlock];
}

void axolotl_game_post_key(int key, int action) {
    AXInputEvent event = {0};
    event.type = AX_EVENT_KEY;
    event.i1 = key;
    event.i3 = action;
    axolotl_input_push(event);
}

void axolotl_game_post_mouse(int button, int action) {
    AXInputEvent event = {0};
    event.type = AX_EVENT_MOUSE_BUTTON;
    event.i1 = button;
    event.i2 = action;
    axolotl_input_push(event);
}

void axolotl_game_move_cursor(double delta_x, double delta_y) {
    g_cursor_x += delta_x;
    g_cursor_y += delta_y;
    AXInputEvent event = {0};
    event.type = AX_EVENT_CURSOR_POS;
    event.f1 = g_cursor_x;
    event.f2 = g_cursor_y;
    axolotl_input_push(event);
}

/// Hands the queued events to the callbacks the game registered.
static void axolotl_input_pump(void) {
    AXInputEvent batch[512];
    int count = 0;
    if (g_event_lock != nil) {
        [g_event_lock lock];
        count = g_event_count;
        memcpy(batch, g_events, (size_t)count * sizeof(AXInputEvent));
        g_event_count = 0;
        [g_event_lock unlock];
    }
    void *window = (void *)g_showing_window;
    for (int index = 0; index < count; index++) {
        AXInputEvent event = batch[index];
        switch (event.type) {
        case AX_EVENT_KEY:
            if (g_callbacks.key != 0) {
                ((void (*)(void *, int, int, int, int))g_callbacks.key)(
                    window, event.i1, event.i2, event.i3, event.i4);
            }
            break;
        case AX_EVENT_MOUSE_BUTTON:
            if (g_callbacks.mouse_button != 0) {
                ((void (*)(void *, int, int, int))g_callbacks.mouse_button)(
                    window, event.i1, event.i2, event.i3);
            }
            break;
        case AX_EVENT_CURSOR_POS:
            if (g_callbacks.cursor_position != 0) {
                ((void (*)(void *, double, double))g_callbacks
                     .cursor_position)(window, event.f1, event.f2);
            }
            break;
        case AX_EVENT_SCROLL:
            if (g_callbacks.scroll != 0) {
                ((void (*)(void *, double, double))g_callbacks.scroll)(
                    window, event.f1, event.f2);
            }
            break;
        default:
            break;
        }
    }
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetCharCallback(void *env,
                                              void *class_ref,
                                              long long window,
                                              long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.character = (intptr_t)pointer;
    return window;
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetCharModsCallback(void *env,
                                                  void *class_ref,
                                                  long long window,
                                                  long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.character_mods = (intptr_t)pointer;
    return window;
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetCursorEnterCallback(void *env,
                                                     void *class_ref,
                                                     long long window,
                                                     long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.cursor_enter = (intptr_t)pointer;
    return window;
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetCursorPosCallback(void *env,
                                                   void *class_ref,
                                                   long long window,
                                                   long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.cursor_position = (intptr_t)pointer;
    return window;
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetFramebufferSizeCallback(void *env,
                                                         void *class_ref,
                                                         long long window,
                                                         long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.framebuffer_size = (intptr_t)pointer;
    return window;
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetKeyCallback(void *env,
                                             void *class_ref,
                                             long long window,
                                             long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.key = (intptr_t)pointer;
    return window;
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetMouseButtonCallback(void *env,
                                                     void *class_ref,
                                                     long long window,
                                                     long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.mouse_button = (intptr_t)pointer;
    return window;
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetScrollCallback(void *env,
                                                void *class_ref,
                                                long long window,
                                                long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.scroll = (intptr_t)pointer;
    return window;
}

AX_PUBLIC long long
Java_org_lwjgl_glfw_GLFW_nglfwSetWindowSizeCallback(void *env,
                                                    void *class_ref,
                                                    long long window,
                                                    long long pointer) {
    (void)env;
    (void)class_ref;
    g_callbacks.window_size = (intptr_t)pointer;
    return window;
}

AX_PUBLIC void Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(void *env,
                                                              void *class_ref,
                                                              long long window) {
    (void)env;
    (void)class_ref;
    (void)window;
}

AX_PUBLIC void
Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(void *env,
                                                     void *class_ref,
                                                     unsigned char grabbing) {
    (void)env;
    (void)class_ref;
    (void)grabbing;
}

AX_PUBLIC void *Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(
    void *env,
    void *class_ref,
    int action,
    void *copy) {
    (void)env;
    (void)class_ref;
    (void)action;
    (void)copy;
    return NULL;
}

#pragma mark - Launch preparation

void axolotl_game_finish(void) {
    dispatch_block_t teardown = ^{
        if (g_game_window == nil) {
            return;
        }
        g_game_window.hidden = YES;
        g_game_window.rootViewController = nil;
        g_game_window = nil;
        g_game_view = nil;
    };
    if ([NSThread isMainThread]) {
        teardown();
    } else {
        dispatch_async(dispatch_get_main_queue(), teardown);
    }
}

int axolotl_game_prepare(const char *runtime_directory) {
    @autoreleasepool {
        if (runtime_directory == NULL) {
            return -1;
        }
        NSString *directory =
            [NSString stringWithUTF8String:runtime_directory];
        NSError *error = nil;
        if (![NSFileManager.defaultManager
                createDirectoryAtPath:directory
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&error]) {
            NSLog(@"[Axolotl] Could not create the runtime directory: %@",
                  error);
            return -2;
        }
        NSString *link = [directory stringByAppendingPathComponent:
                                         @"AngelAuraAmethyst"];
        NSString *executable = [NSBundle.mainBundle executablePath];
        if (![NSFileManager.defaultManager
                createSymbolicLinkAtPath:link
                     withDestinationPath:executable
                                   error:&error]) {
            // An existing link is expected on later launches.
            if (![NSFileManager.defaultManager fileExistsAtPath:link]) {
                NSLog(@"[Axolotl] Could not link the launcher executable: %@",
                      error);
                return -3;
            }
        }
        setenv("BUNDLE_PATH", directory.UTF8String, 1);
        return 0;
    }
}
