#import "AxolotlGame.h"

#import <UIKit/UIKit.h>

#include <math.h>

/// On-screen controls over the game surface.
///
/// The game expects a window system that reports a keyboard and a pointer.
/// Touch input has neither, so this overlay turns a movement stick, a drag area
/// and a small button row into the key and mouse events the game reads.

static const CGFloat kStickRadius = 62.0;
static const CGFloat kButtonSize = 58.0;
static const CGFloat kStickMargin = 24.0;

typedef NS_ENUM(NSInteger, AXControlKind) {
    AXControlKindKey,
    AXControlKindMouse,
};

typedef struct {
    const char *title;
    CGFloat center_x;
    CGFloat center_y;
    AXControlKind kind;
    int code;
} AXControlDefinition;

/// Positions are fractions of the overlay size so the same layout works on every
/// screen the application runs on.
static const AXControlDefinition kControls[] = {
    {"跳", 0.86, 0.78, AXControlKindKey, AX_KEY_SPACE},
    {"蹲", 0.86, 0.90, AXControlKindKey, AX_KEY_LEFT_SHIFT},
    {"攻", 0.74, 0.90, AXControlKindMouse, AX_MOUSE_LEFT},
    {"用", 0.74, 0.78, AXControlKindMouse, AX_MOUSE_RIGHT},
    {"包", 0.62, 0.90, AXControlKindKey, AX_KEY_E},
    {"退", 0.98, 0.30, AXControlKindKey, AX_KEY_ESCAPE},
};

static const size_t kControlCount = sizeof(kControls) / sizeof(kControls[0]);

@interface AxolotlControlsView : UIView
@end

@implementation AxolotlControlsView {
    CGPoint _stick_center;
    CGPoint _stick_knob;
    NSInteger _stick_touch;
    NSInteger _look_touch;
    CGPoint _look_previous;
    BOOL _directions[4];
    NSMutableDictionary<NSNumber *, NSNumber *> *_held_controls;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = YES;
        _stick_touch = -1;
        _look_touch = -1;
        _held_controls = [NSMutableDictionary dictionary];
        [self layoutForBounds:self.bounds];
    }
    return self;
}

- (void)layoutForBounds:(CGRect)bounds {
    _stick_center =
        CGPointMake(bounds.size.width * 0.18,
                    bounds.size.height - kStickMargin - kStickRadius);
    if (_stick_knob.x == 0 && _stick_knob.y == 0) {
        _stick_knob = _stick_center;
    }
    [self setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutForBounds:self.bounds];
}

- (CGPoint)buttonCenter:(const AXControlDefinition *)control {
    return CGPointMake(self.bounds.size.width * control->center_x,
                       self.bounds.size.height * control->center_y);
}

- (const AXControlDefinition *)controlAtPoint:(CGPoint)point {
    for (size_t index = 0; index < kControlCount; index++) {
        CGPoint center = [self buttonCenter:&kControls[index]];
        CGRect rect = CGRectMake(center.x - kButtonSize / 2,
                                 center.y - kButtonSize / 2, kButtonSize,
                                 kButtonSize);
        if (CGRectContainsPoint(rect, point)) {
            return &kControls[index];
        }
    }
    return NULL;
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context == NULL) {
        return;
    }
    CGContextSetLineWidth(context, 2.0);
    [[UIColor colorWithWhite:1.0 alpha:0.35] setStroke];
    [[UIColor colorWithWhite:0.1 alpha:0.28] setFill];

    CGContextFillEllipseInRect(
        context, CGRectMake(_stick_center.x - kStickRadius,
                            _stick_center.y - kStickRadius,
                            kStickRadius * 2, kStickRadius * 2));
    CGContextStrokeEllipseInRect(
        context, CGRectMake(_stick_center.x - kStickRadius,
                            _stick_center.y - kStickRadius,
                            kStickRadius * 2, kStickRadius * 2));

    CGFloat knob = kStickRadius * 0.45;
    [[UIColor colorWithWhite:1.0 alpha:0.5] setFill];
    CGContextFillEllipseInRect(
        context, CGRectMake(_stick_knob.x - knob, _stick_knob.y - knob,
                            knob * 2, knob * 2));

    NSDictionary *attributes = @{
        NSFontAttributeName : [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName : [UIColor colorWithWhite:1.0 alpha:0.85],
    };
    for (size_t index = 0; index < kControlCount; index++) {
        const AXControlDefinition *control = &kControls[index];
        CGPoint center = [self buttonCenter:control];
        CGRect circle = CGRectMake(center.x - kButtonSize / 2,
                                   center.y - kButtonSize / 2, kButtonSize,
                                   kButtonSize);
        [[UIColor colorWithWhite:0.1 alpha:0.35] setFill];
        CGContextFillEllipseInRect(context, circle);
        CGContextStrokeEllipseInRect(context, circle);
        NSString *title =
            [NSString stringWithUTF8String:control->title];
        CGSize size = [title sizeWithAttributes:attributes];
        [title drawAtPoint:CGPointMake(center.x - size.width / 2,
                                       center.y - size.height / 2)
            withAttributes:attributes];
    }
}

#pragma mark - Touch handling

- (void)applyDirection:(NSUInteger)index pressed:(BOOL)pressed {
    static const int keys[4] = {AX_KEY_W, AX_KEY_S, AX_KEY_A, AX_KEY_D};
    if (_directions[index] == pressed) {
        return;
    }
    _directions[index] = pressed;
    axolotl_game_post_key(keys[index],
                          pressed ? AX_KEY_PRESS : AX_KEY_RELEASE);
}

- (void)updateDirectionsForOffset:(CGPoint)offset {
    CGFloat threshold = kStickRadius * 0.38;
    [self applyDirection:0 pressed:offset.y < -threshold];
    [self applyDirection:1 pressed:offset.y > threshold];
    [self applyDirection:2 pressed:offset.x < -threshold];
    [self applyDirection:3 pressed:offset.x > threshold];
}

- (void)releaseDirections {
    for (NSUInteger index = 0; index < 4; index++) {
        [self applyDirection:index pressed:NO];
    }
}

- (void)pressControl:(NSNumber *)identifier {
    const AXControlDefinition *control =
        [self controlAtPoint:[self locationOfTouch:identifier]];
    if (control == NULL) {
        return;
    }
    NSInteger key = (NSInteger)(control - kControls);
    if (_held_controls[identifier] != nil) {
        return;
    }
    _held_controls[identifier] = @(key);
    if (control->kind == AXControlKindKey) {
        axolotl_game_post_key(control->code, AX_KEY_PRESS);
    } else {
        axolotl_game_post_mouse(control->code, AX_KEY_PRESS);
    }
}

- (void)releaseControlForTouch:(NSNumber *)identifier {
    NSNumber *held = _held_controls[identifier];
    if (held == nil) {
        return;
    }
    const AXControlDefinition *control = &kControls[held.integerValue];
    if (control->kind == AXControlKindKey) {
        axolotl_game_post_key(control->code, AX_KEY_RELEASE);
    } else {
        axolotl_game_post_mouse(control->code, AX_KEY_RELEASE);
    }
    [_held_controls removeObjectForKey:identifier];
}

- (CGPoint)locationOfTouch:(NSNumber *)identifier {
    for (UITouch *touch in self.allTouches) {
        if ([@((uintptr_t)touch) isEqualToNumber:identifier]) {
            return [touch locationInView:self];
        }
    }
    return CGPointZero;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self];
        NSNumber *identifier = @((uintptr_t)touch);
        if (hypot(point.x - _stick_center.x, point.y - _stick_center.y) <
                kStickRadius * 1.35 &&
            _stick_touch < 0) {
            _stick_touch = (NSInteger)touch;
            [self moveStickTo:point];
            continue;
        }
        if ([self controlAtPoint:point] != NULL) {
            [self pressControl:identifier];
            continue;
        }
        if (_look_touch < 0) {
            _look_touch = (NSInteger)touch;
            _look_previous = point;
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self];
        if ((NSInteger)touch == _stick_touch) {
            [self moveStickTo:point];
            continue;
        }
        if ((NSInteger)touch == _look_touch) {
            axolotl_game_move_cursor(point.x - _look_previous.x,
                                     point.y - _look_previous.y);
            _look_previous = point;
            continue;
        }
        [self releaseControlForTouch:@((uintptr_t)touch)];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        [self finishTouch:touch];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        [self finishTouch:touch];
    }
}

- (void)finishTouch:(UITouch *)touch {
    if ((NSInteger)touch == _stick_touch) {
        _stick_touch = -1;
        _stick_knob = _stick_center;
        [self releaseDirections];
        [self setNeedsDisplay];
        return;
    }
    if ((NSInteger)touch == _look_touch) {
        _look_touch = -1;
        return;
    }
    [self releaseControlForTouch:@((uintptr_t)touch)];
}

- (void)moveStickTo:(CGPoint)point {
    CGPoint offset = CGPointMake(point.x - _stick_center.x,
                                 point.y - _stick_center.y);
    CGFloat distance = hypot(offset.x, offset.y);
    if (distance > kStickRadius) {
        offset.x = offset.x / distance * kStickRadius;
        offset.y = offset.y / distance * kStickRadius;
    }
    _stick_knob =
        CGPointMake(_stick_center.x + offset.x, _stick_center.y + offset.y);
    [self updateDirectionsForOffset:offset];
    [self setNeedsDisplay];
}

@end

UIView *axolotl_controls_view(CGRect bounds) {
    return [[AxolotlControlsView alloc] initWithFrame:bounds];
}
