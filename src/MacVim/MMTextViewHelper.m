/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */
/*
 * MMTextViewHelper
 *
 * Contains code shared between the different text renderers.  Unfortunately it
 * is not possible to let the text renderers inherit from this class since
 * MMTextView needs to inherit from NSTextView whereas MMCoreTextView needs to
 * inherit from NSView.
 */

#import "MMTextView.h"
#import "MMTextViewHelper.h"
#import "MMVimController.h"
#import "MMWindowController.h"
#import "Miscellaneous.h"


// The max/min drag timer interval in seconds
static NSTimeInterval MMDragTimerMaxInterval = 0.3;
static NSTimeInterval MMDragTimerMinInterval = 0.01;

// The number of pixels in which the drag timer interval changes
static float MMDragAreaSize = 73.0f;


@interface MMTextViewHelper (Private)
- (MMWindowController *)windowController;
- (MMVimController *)vimController;
- (void)doKeyDown:(NSString *)key;
- (void)doInsertText:(NSString *)text;
- (void)hideMouseCursor;
- (void)startDragTimerWithInterval:(NSTimeInterval)t;
- (void)dragTimerFired:(NSTimer *)timer;
- (void)setCursor;
- (NSRect)trackingRect;
- (BOOL)inputManagerHandleMouseEvent:(NSEvent *)event;
- (void)sendMarkedText:(NSString *)text position:(int32_t)pos length:(unsigned)len;
- (void)abandonMarkedText;
- (void)sendGestureEvent:(int)gesture flags:(unsigned)flags;
@end




    static BOOL
KeyboardInputSourcesEqual(TISInputSourceRef a, TISInputSourceRef b)
{
    // Define two sources to be equal iff both are non-NULL and they have
    // identical source ID strings.

    if (!(a && b))
        return NO;

    NSString *as = TISGetInputSourceProperty(a, kTISPropertyInputSourceID);
    NSString *bs = TISGetInputSourceProperty(b, kTISPropertyInputSourceID);

    return [as isEqualToString:bs];
}


@implementation MMTextViewHelper

- (id)init
{
    if (!(self = [super init]))
        return nil;

    signImages = [[NSMutableDictionary alloc] init];

    useMouseTime =
        [[NSUserDefaults standardUserDefaults] boolForKey:MMUseMouseTimeKey];
    if (useMouseTime)
        mouseDownTime = [[NSDate date] retain];

    return self;
}

- (void)dealloc
{
    ASLogDebug(@"");

    [insertionPointColor release];  insertionPointColor = nil;
    [markedText release];  markedText = nil;
    [markedTextAttributes release];  markedTextAttributes = nil;
    [signImages release];  signImages = nil;
    [mouseDownTime release];  mouseDownTime = nil;

    if (asciiImSource) {
        CFRelease(asciiImSource);
        asciiImSource = NULL;
    }
    if (lastImSource) {
        CFRelease(lastImSource);
        lastImSource = NULL;
    }

    [super dealloc];
}

- (void)setTextView:(id)view
{
    // Only keep a weak reference to owning text view.
    textView = view;
}

- (void)setInsertionPointColor:(NSColor *)color
{
    if (color != insertionPointColor) {
        [insertionPointColor release];
        insertionPointColor = [color retain];
    }
}

- (NSColor *)insertionPointColor
{
    return insertionPointColor;
}

- (void)keyDown:(NSEvent *)event
{
    ASLogDebug(@"%@", event);

    // NOTE: Keyboard handling is complicated by the fact that we must call
    // interpretKeyEvents: otherwise key equivalents set up by input methods do
    // not work (e.g. Ctrl-Shift-; would not work under Kotoeri).

    // NOTE: insertText: and doCommandBySelector: may need to extract data from
    // the key down event so keep a local reference to the event.  This is
    // released and set to nil at the end of this method.  Don't make any early
    // returns from this method without releasing and resetting this reference!
    currentEvent = [event retain];

    if ([self hasMarkedText]) {
        // HACK! Need to redisplay manually otherwise the marked text may not
        // be correctly displayed (e.g. it is still visible after pressing Esc
        // even though the text has been unmarked).
        [textView setNeedsDisplay:YES];
    }

    [self hideMouseCursor];

    NSUInteger flags = [event modifierFlags];
    id mmta = [[[self vimController] vimState] objectForKey:@"p_mmta"];
    NSString *string = [event characters];
    NSString *unmod  = [event charactersIgnoringModifiers];
    BOOL modCommand = (flags & NSEventModifierFlagCommand) ? YES : NO;
    BOOL modControl = (flags & NSEventModifierFlagControl) ? YES : NO;
    BOOL modOption = (flags & NSEventModifierFlagOption) ? YES : NO;
    BOOL modShift = (flags & NSEventModifierFlagShift) ? YES : NO;

    // Alt key presses should not be interpreted if the 'macmeta' option is
    // set.  We still have to call interpretKeyEvents: for keys
    // like Enter, Esc, etc. to work as usual so only skip interpretation for
    // ASCII chars in the range after space (0x20) and before backspace (0x7f).
    // Note that this implies that 'mmta' (if enabled) breaks input methods
    // when the Alt key is held.
    if (modOption && [mmta boolValue] && [unmod length] == 1
            && [unmod characterAtIndex:0] > 0x20) {
        ASLogDebug(@"MACMETA key, don't interpret it");
        string = unmod;
    } else if (imState && (modControl && !modCommand && !modOption)
            && [unmod length] == 1
            && ([unmod characterAtIndex:0] == '6' ||
                [unmod characterAtIndex:0] == '^')) {
        // HACK! interpretKeyEvents: does not call doCommandBySelector:
        // with Ctrl-6 or Ctrl-^ when IM is active.
        [self doKeyDown:@"\x1e"];
        string = nil;
    } else {
        // HACK! When using JapaneseIM with "Windows-like shortcuts" turned on,
        // interpretKeyEvents: does not call doCommandBySelector: with Ctrl-O
        // and Ctrl-U (why?), so we cannot handle them at all.
        // As a workaround, we do not call interpretKeyEvents: with Ctrl-O or
        // Ctrl-U when there is no marked text.
        BOOL isJapaneseIME = [[[NSTextInputContext currentInputContext]
                               selectedKeyboardInputSource]
                              hasPrefix:@"com.apple.inputmethod.Kotoeri"];
        BOOL isJapaneseIMCtrlUO = (isJapaneseIME
                                   && (modControl && !modCommand && !modOption)
                                   && ([unmod characterAtIndex:0] == 'o' ||
                                       [unmod characterAtIndex:0] == 'u'));

        if ([self hasMarkedText] || !isJapaneseIMCtrlUO) {
            // interpretKeyEvents: may call insertText: or doCommandBySelector:,
            // or it may swallow the key (most likely the current input method
            // used it).  In the first two cases we have to manually set the
            // below flag to NO if the key wasn't handled, which allows us to
            // manually send the key down event.
            //
            // doCommandBySelector: will also perform misc translations such as
            // Ctrl-6 -> Ctrl-^, so this should not be skipped unless there are
            // special cases like the Japanese IME Ctrl-U issue.
            interpretKeyEventsSwallowedKey = YES;
            [textView interpretKeyEvents:[NSArray arrayWithObject:event]];
            if (interpretKeyEventsSwallowedKey)
                string = nil;
        }
        if (string && modCommand) {
            // HACK! When Command is held we have to more or less guess whether
            // we should use characters or charactersIgnoringModifiers.  The
            // following heuristic seems to work but it may have to change.
            // Note that the Shift and Alt flags may also need to be cleared
            // (see doKeyDown:keyCode:modifiers: in MMBackend).
            if ((modShift && !modOption) || modControl)
                string = unmod;
        }
    }

    if (string)
        [self doKeyDown:string];

    [currentEvent release];
    currentEvent = nil;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    if ([self hasMarkedText]) {
        [self sendMarkedText:nil position:0 length:0];

        // NOTE: If this call is left out then the marked text isn't properly
        // erased when Return is used to accept the text.
        // The input manager only ever sets new marked text, it never actually
        // calls to have it unmarked.  It seems that whenever insertText: is
        // called the input manager expects the marked text to be unmarked
        // automatically, hence the explicit unmarkText: call here.
        [self unmarkText];
    }

    // NOTE: 'string' is either an NSString or an NSAttributedString.  Since we
    // do not support attributes, simply pass the corresponding NSString in the
    // latter case.
    if ([string isKindOfClass:[NSAttributedString class]])
        string = [string string];

    if (replacementRange.length > 0)
    {
        // Replacement range is a concept we don't really have a way to fulfill
        // as we don't have proper access to the underlying text storage. This
        // should usually be triggered when we have selected text though, and
        // so we simply ask Vim to replace the current selection with the new
        // text, and it should hopefully work.
        // Only known way of this being called is Apple Intelligence Writing
        // Tools.
        MMVimController *vc = [self vimController];
        [vc replaceSelectedText:string];
        return;
    }

    //int len = [string length];
    //ASLogDebug(@"len=%d char[0]=%#x char[1]=%#x string='%@'", [string length],
    //        [string characterAtIndex:0],
    //        len > 1 ? [string characterAtIndex:1] : 0, string);

    [self doInsertText:string];
}

- (void)doCommandBySelector:(SEL)sel
{
    ASLogDebug(@"%@", NSStringFromSelector(sel));

    // Translate Ctrl-2 -> Ctrl-@ (see also Resources/KeyBinding.plist)
    if (@selector(keyCtrlAt:) == sel)
        [self doKeyDown:@"\x00"];
    // Translate Ctrl-6 -> Ctrl-^ (see also Resources/KeyBinding.plist)
    else if (@selector(keyCtrlHat:) == sel)
        [self doKeyDown:@"\x1e"];
    //
    // Check for selectors from AppKit.framework/StandardKeyBinding.dict and
    // send the corresponding key directly on to the backend.  The reason for
    // not just letting all of these fall through is that -[NSEvent characters]
    // sometimes includes marked text as well as the actual key, but the marked
    // text is also passed to insertText:.  For example, pressing Ctrl-i Return
    // on a US keyboard would call insertText:@"^" but the key event for the
    // Return press will contain "^\x0d" -- if we fell through the result would
    // be that "^^\x0d" got sent to the backend (i.e. one extra "^" would
    // appear).
    // For this reason we also have to make sure that there are key bindings to
    // all combinations of modifier with certain keys (these are set up in
    // KeyBinding.plist in the Resources folder).
    else if (@selector(insertTab:) == sel ||
             @selector(selectNextKeyView:) == sel ||
             @selector(insertTabIgnoringFieldEditor:) == sel)
        [self doKeyDown:@"\x09"];
    else if (@selector(insertNewline:) == sel ||
             @selector(insertLineBreak:) == sel ||
             @selector(insertNewlineIgnoringFieldEditor:) == sel)
        [self doKeyDown:@"\x0d"];
    else if (@selector(cancelOperation:) == sel ||
             @selector(complete:) == sel)
        [self doKeyDown:@"\x1b"];
    else if (@selector(insertBackTab:) == sel ||
             @selector(selectPreviousKeyView:) == sel)
        [self doKeyDown:@"\x19"];
    else if (@selector(deleteBackward:) == sel ||
             @selector(deleteWordBackward:) == sel ||
             @selector(deleteBackwardByDecomposingPreviousCharacter:) == sel ||
             @selector(deleteToBeginningOfLine:) == sel)
        [self doKeyDown:@"\x08"];
    else if (@selector(keySpace:) == sel)
        [self doKeyDown:@" "];
    else if (@selector(cancel:) == sel)
        kill([[self vimController] pid], SIGINT);
    else interpretKeyEventsSwallowedKey = NO;
}

- (void)calcScrollWheelDeltas:(NSEvent *)event x:(float *)x y:(float *)y eventFlags:(NSEventModifierFlags*)eventFlags
{
    float dx = 0;
    float dy = 0;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    if ([event hasPreciseScrollingDeltas]) {
        const NSEventPhase phase = event.phase;

        CGFloat eventScrollingDeltaX = event.scrollingDeltaX;
        CGFloat eventScrollingDeltaY = event.scrollingDeltaY;

        // If user wants to only scroll in one direction to prevent accidental
        // side scroll, we lock that in at the beginning of a scroll gesture.
        // Note that we choose Y if both X and Y deltas exist, because most of
        // the time, the user is doing a vertical scroll.
        if (phase == NSEventPhaseMayBegin || phase == NSEventPhaseBegan) {
            scrollingDirection = ScrollingDirectionUnknown;
        }
        if (scrollingDirection == ScrollingDirectionUnknown) {
            if (event.scrollingDeltaY != 0) {
                scrollingDirection = ScrollingDirectionVertical;
            } else if (event.scrollingDeltaX != 0) {
                scrollingDirection = ScrollingDirectionHorizontal;
            }
        }
        if ([ud boolForKey:MMScrollOneDirectionOnlyKey]) {
            if (scrollingDirection == ScrollingDirectionVertical) {
                eventScrollingDeltaX = 0;
            } else if (scrollingDirection == ScrollingDirectionHorizontal) {
                eventScrollingDeltaY = 0;
            }
        }

        const NSSize cellSize = [textView cellSize];
        const float thresholdX = cellSize.width;
        const float thresholdY = cellSize.height;

        scrollingDeltaX += eventScrollingDeltaX;
        if (fabs(scrollingDeltaX) > thresholdX) {
            dx = roundf(scrollingDeltaX / thresholdX);
            scrollingDeltaX -= thresholdX * dx;
        }
        scrollingDeltaY += eventScrollingDeltaY;
        if (fabs(scrollingDeltaY) > thresholdY) {
            dy = roundf(scrollingDeltaY / thresholdY);
            scrollingDeltaY -= thresholdY * dy;
        }
    } else {
        scrollingDeltaX = 0;
        scrollingDeltaY = 0;
        dx = [event scrollingDeltaX];
        dy = [event scrollingDeltaY];

        if ([ud boolForKey:MMMouseWheelDisableAccelerationKey]) {
            // Use scroll wheel as discrete steps as macOS acceleration often
            // leads to unintuitive results.
            NSInteger numLines = [ud integerForKey:MMMouseWheelNumLinesKey];
            dx = dx == 0 ? 0 : (dx > 0 ? numLines : -numLines);
            dy = dy == 0 ? 0 : (dy > 0 ? numLines : -numLines);
        } else {
            // Use the default OS acceleration, but we still want to round up
            // the delta to at least 1 (configurable) as otherwise it's
            // frustrating to use as MacVim fails to scroll even one line.
            NSInteger minScrollLines = [ud integerForKey:MMMouseWheelMinLinesKey];
            dx = dx == 0 ? 0 : (fabs(dx) > minScrollLines ? dx : (dx > 0 ? minScrollLines : -minScrollLines));
            dy = dy == 0 ? 0 : (fabs(dy) > minScrollLines ? dy : (dy > 0 ? minScrollLines : -minScrollLines));
        }

        if ((*eventFlags & NSEventModifierFlagShift) && dx != 0 && dy == 0) {
            // A shift-scroll in macOS converts a normal Y to X-axis scroll.
            // There is no proper API to query this so this is just done by
            // heuristics. We need to remove the shift flag, or Vim would see
            // this as a <S-ScrollWheelRight> which is not what we want.
            *eventFlags = *eventFlags & (~NSEventModifierFlagShift);
        }
    }

    *x = dx;
    *y = dy;
}

- (void)scrollWheel:(NSEvent *)event
{
    NSEventModifierFlags eventFlags = event.modifierFlags;
    float dx = 0, dy = 0;
    [self calcScrollWheelDeltas:event x:&dx y:&dy eventFlags:&eventFlags];
    if (dx == 0 && dy == 0)
        return;

    if ([self hasMarkedText]) {
        // We must clear the marked text since the cursor may move if the
        // marked text moves outside the view as a result of scrolling.
        [self sendMarkedText:nil position:0 length:0];
        [self unmarkText];
        [[NSTextInputContext currentInputContext] discardMarkedText];
    }

    int row, col;
    NSPoint pt = [textView convertPoint:[event locationInWindow] fromView:nil];
    if ([textView convertPoint:pt toRow:&row column:&col]) {
        unsigned flags = (unsigned)eventFlags;
        NSMutableData *data = [NSMutableData data];

        [data appendBytes:&row length:sizeof(int)];
        [data appendBytes:&col length:sizeof(int)];
        [data appendBytes:&flags length:sizeof(unsigned)];
        [data appendBytes:&dy length:sizeof(float)];
        [data appendBytes:&dx length:sizeof(float)];

        [[self vimController] sendMessage:ScrollWheelMsgID data:data];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    if ([self inputManagerHandleMouseEvent:event])
        return;

    int row, col;
    NSPoint pt = [textView convertPoint:[event locationInWindow] fromView:nil];
    if (![textView convertPoint:pt toRow:&row column:&col])
        return;

    int button = (int)[event buttonNumber];
    unsigned flags = (unsigned)[event modifierFlags];
    int repeat = 0;

    if (useMouseTime) {
        // Use Vim mouseTime option to handle multiple mouse down events
        NSDate *now = [[NSDate date] retain];
        id mouset = [[[self vimController] vimState] objectForKey:@"p_mouset"];
        NSTimeInterval interval =
            [now timeIntervalSinceDate:mouseDownTime] * 1000.0;
        if (interval < (NSTimeInterval)[mouset longValue])
            repeat = 1;
        mouseDownTime = now;
    } else {
        repeat = [event clickCount] > 1;
    }

    NSMutableData *data = [NSMutableData data];

    // If desired, intepret Ctrl-Click as a right mouse click.
    BOOL translateCtrlClick = [[NSUserDefaults standardUserDefaults]
            boolForKey:MMTranslateCtrlClickKey];
    flags = flags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (translateCtrlClick && button == 0 &&
            (flags == NSEventModifierFlagControl || flags ==
                 (NSEventModifierFlagControl|NSEventModifierFlagCapsLock))) {
        button = 1;
        flags &= ~NSEventModifierFlagControl;
    }

    [data appendBytes:&row length:sizeof(int)];
    [data appendBytes:&col length:sizeof(int)];
    [data appendBytes:&button length:sizeof(int)];
    [data appendBytes:&flags length:sizeof(unsigned)];
    [data appendBytes:&repeat length:sizeof(int)];

    [[self vimController] sendMessage:MouseDownMsgID data:data];
}

- (void)mouseUp:(NSEvent *)event
{
    if ([self inputManagerHandleMouseEvent:event])
        return;

    int row, col;
    NSPoint pt = [textView convertPoint:[event locationInWindow] fromView:nil];
    if (![textView convertPoint:pt toRow:&row column:&col])
        return;

    unsigned flags = (unsigned)[event modifierFlags];
    NSMutableData *data = [NSMutableData data];

    [data appendBytes:&row length:sizeof(int)];
    [data appendBytes:&col length:sizeof(int)];
    [data appendBytes:&flags length:sizeof(unsigned)];

    [[self vimController] sendMessage:MouseUpMsgID data:data];

    isDragging = NO;
}

- (void)mouseDragged:(NSEvent *)event
{
    if ([self inputManagerHandleMouseEvent:event])
        return;

    unsigned flags = (unsigned)[event modifierFlags];
    int row, col;
    NSPoint pt = [textView convertPoint:[event locationInWindow] fromView:nil];
    if (![textView convertPoint:pt toRow:&row column:&col])
        return;

    // Autoscrolling is done in dragTimerFired:
    if (!isAutoscrolling) {
        NSMutableData *data = [NSMutableData data];

        [data appendBytes:&row length:sizeof(int)];
        [data appendBytes:&col length:sizeof(int)];
        [data appendBytes:&flags length:sizeof(unsigned)];

        [[self vimController] sendMessage:MouseDraggedMsgID data:data];
    }

    dragPoint = pt;
    dragRow = row;
    dragColumn = col;
    dragFlags = flags;

    if (!isDragging) {
        [self startDragTimerWithInterval:.5];
        isDragging = YES;
    }
}

- (void)mouseMoved:(NSEvent *)event
{
    if ([self inputManagerHandleMouseEvent:event])
        return;

    // HACK! NSTextView has a nasty habit of resetting the cursor to the
    // default I-beam cursor at random moments.  The only reliable way we know
    // of to work around this is to set the cursor each time the mouse moves.
    [self setCursor];

    NSPoint pt = [textView convertPoint:[event locationInWindow] fromView:nil];
    int row, col;
    if (![textView convertPoint:pt toRow:&row column:&col])
        return;

    NSMutableData *data = [NSMutableData data];

    [data appendBytes:&row length:sizeof(int)];
    [data appendBytes:&col length:sizeof(int)];

    [[self vimController] sendMessage:MouseMovedMsgID data:data];
}

- (void)swipeWithEvent:(NSEvent *)event
{
    CGFloat dx = [event deltaX];
    CGFloat dy = [event deltaY];
    int type;
    if (dx > 0)	     type = MMGestureSwipeLeft;
    else if (dx < 0) type = MMGestureSwipeRight;
    else if (dy > 0) type = MMGestureSwipeUp;
    else if (dy < 0) type = MMGestureSwipeDown;
    else return;

    [self sendGestureEvent:type flags:(unsigned)[event modifierFlags]];
}

- (void)pressureChangeWithEvent:(NSEvent *)event
{
    static BOOL inForceClick = NO;
    if (event.stage >= 2) {
        if (!inForceClick) {
            inForceClick = YES;

            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

            // See if the OS is configured to use Force click for data lookups
            // (the other option usually being three-finger tap).
            const BOOL useForceClickLookup = [ud boolForKey:@"com.apple.trackpad.forceClick"];

            // See if the user has overriden to disallow Force click lookups.
            // The usual reason for disallowing it is to support binding
            // <ForceClick> mappings in Vim.
            const BOOL userAllowsForceClickLookup = [ud boolForKey:MMAllowForceClickLookUpKey];

            if (useForceClickLookup && userAllowsForceClickLookup) {
                // For some odd reason, we don't get quickLookWithEvent: even when
                // the user has configured to use force click instead of 3-finger
                // tap. We need to manually invoke it (this is how NSTextView does
                // it as well). References for other software that do this:
                //   https://gitlab.com/gnachman/iterm2/-/blob/master/sources/PointerController.m
                //   https://searchfox.org/mozilla-central/source/widget/cocoa/nsChildView.mm
                [textView quickLookWithEvent:event];
            } else {
                [self sendGestureEvent:MMGestureForceClick flags:(unsigned)[event modifierFlags]];
            }
        }
    } else {
        inForceClick = NO;
    }
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    NSPasteboard *pboard = [sender draggingPasteboard];

    if ([[pboard types] containsObject:NSPasteboardTypeString]) {
        NSString *string = [pboard stringForType:NSPasteboardTypeString];
        [[self vimController] dropString:string];
        return YES;
    } else if ([[pboard types] containsObject:getPasteboardFilenamesType()]) {
        NSArray<NSString *> *filenames = extractPasteboardFilenames(pboard);
        [[self vimController] dropFiles:filenames forceOpen:NO];
        return YES;
    }

    return NO;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];
    NSPasteboard *pboard = [sender draggingPasteboard];

    if ( [[pboard types] containsObject:getPasteboardFilenamesType()]
            && (sourceDragMask & NSDragOperationCopy) )
        return NSDragOperationCopy;
    if ( [[pboard types] containsObject:NSPasteboardTypeString]
            && (sourceDragMask & NSDragOperationCopy) )
        return NSDragOperationCopy;

    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];
    NSPasteboard *pboard = [sender draggingPasteboard];

    if ( [[pboard types] containsObject:getPasteboardFilenamesType()]
            && (sourceDragMask & NSDragOperationCopy) )
        return NSDragOperationCopy;
    if ( [[pboard types] containsObject:NSPasteboardTypeString]
            && (sourceDragMask & NSDragOperationCopy) )
        return NSDragOperationCopy;

    return NSDragOperationNone;
}

- (void)setMouseShape:(int)shape
{
    mouseShape = shape;
    [self setCursor];
}

- (void)changeFont:(id)sender
{
    NSFont *newFont = [sender convertFont:[textView font]];
    NSFont *newFontWide = [sender convertFont:[textView fontWide]];

    if (newFont) {
        NSString *name = [newFont displayName];
        NSString *wideName = [newFontWide displayName];
        unsigned len = (unsigned)[name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        unsigned wideLen = (unsigned)[wideName lengthOfBytesUsingEncoding:
                                                        NSUTF8StringEncoding];
        if (len > 0) {
            NSMutableData *data = [NSMutableData data];
            float pointSize = [newFont pointSize];

            [data appendBytes:&pointSize length:sizeof(float)];

            ++len;  // include NUL byte
            [data appendBytes:&len length:sizeof(unsigned)];
            [data appendBytes:[name UTF8String] length:len];

            if (wideLen > 0) {
                ++wideLen;  // include NUL byte
                [data appendBytes:&wideLen length:sizeof(unsigned)];
                [data appendBytes:[wideName UTF8String] length:wideLen];
            } else {
                [data appendBytes:&wideLen length:sizeof(unsigned)];
            }

            [[self vimController] sendMessage:SetFontMsgID data:data];
        }
    }
}

- (NSImage *)signImageForName:(NSString *)imgName
{
    NSImage *img = [signImages objectForKey:imgName];
    if (img)
        return img;

    img = [[NSImage alloc] initWithContentsOfFile:imgName];
    if (img) {
        [signImages setObject:img forKey:imgName];
        [img autorelease];
    }

    return img;
}

- (void)deleteImage:(NSString *)imgName
{
    [signImages removeObjectForKey:imgName];
}

- (BOOL)hasMarkedText
{
    return markedRange.length > 0 ? YES : NO;
}

- (NSRange)markedRange
{
    if ([self hasMarkedText])
        return markedRange;
    else
        return NSMakeRange(NSNotFound, 0);
}

- (NSDictionary *)markedTextAttributes
{
    return markedTextAttributes;
}

- (void)setMarkedTextAttributes:(NSDictionary *)attr
{
    ASLogDebug(@"%@", attr);
    if (attr != markedTextAttributes) {
        [markedTextAttributes release];
        markedTextAttributes = [attr retain];
    }
}

- (void)setMarkedText:(id)text selectedRange:(NSRange)range
{
    ASLogDebug(@"text='%@' range=%@", text, NSStringFromRange(range));
    [self unmarkText];

    if ([self useInlineIm]) {
        if ([text isKindOfClass:[NSAttributedString class]])
            text = [text string];

        if ([text length] > 0) {
            markedRange = NSMakeRange(0, [text length]);
            imRange = range;
        }

        [self sendMarkedText:text position:(int32_t)range.location length:range.length];
        return;
    }

#ifdef INCLUDE_OLD_IM_CODE
    if (!(text && [text length] > 0))
        return;

    // HACK! Determine if the marked text is wide or normal width.  This seems
    // to always use 'wide' when there are both wide and normal width
    // characters.
    NSString *string = text;
    NSFont *theFont = [textView font];
    if ([text isKindOfClass:[NSAttributedString class]]) {
        theFont = [textView fontWide];
        string = [text string];
    }

    // TODO: Use special colors for marked text.
    [self setMarkedTextAttributes:
        [NSDictionary dictionaryWithObjectsAndKeys:
            theFont, NSFontAttributeName,
            [textView defaultBackgroundColor], NSBackgroundColorAttributeName,
            [textView defaultForegroundColor], NSForegroundColorAttributeName,
            nil]];

    markedText = [[NSMutableAttributedString alloc]
           initWithString:string
               attributes:[self markedTextAttributes]];

    markedRange = NSMakeRange(0, [markedText length]);
    if (markedRange.length) {
        [markedText addAttribute:NSUnderlineStyleAttributeName
                           value:[NSNumber numberWithInt:1]
                           range:markedRange];
    }
    imRange = range;
    if (range.length) {
        [markedText addAttribute:NSUnderlineStyleAttributeName
                           value:[NSNumber numberWithInt:2]
                           range:range];
    }

    [textView setNeedsDisplay:YES];
#endif // INCLUDE_OLD_IM_CODE
}

- (void)unmarkText
{
    ASLogDebug(@"");
    imRange = NSMakeRange(0, 0);
    markedRange = NSMakeRange(NSNotFound, 0);
    [markedText release];
    markedText = nil;
}

- (NSMutableAttributedString *)markedText
{
    return markedText;
}

- (void)setPreEditRow:(int)row column:(int)col
{
    preEditRow = row;
    preEditColumn = col;
}

- (int)preEditRow
{
    return preEditRow;
}

- (int)preEditColumn
{
    return preEditColumn;
}

- (void)setImRange:(NSRange)range
{
    imRange = range;
}

- (NSRange)imRange
{
    return imRange;
}

- (void)setMarkedRange:(NSRange)range
{
    markedRange = range;
}

/// Don't use this. See comments.
- (NSRect)firstRectForCharacterRange:(NSRange)range
{
    //
    // Note: This is really quite a buggy method and relies on improper
    // assumptions. It's kept alive for now because MMTextView (which is also
    // deprecated and shouldn't be used for real users) uses this.
    // Known bugs:
    // - Assumes that preEditRow/Column is the beginning of the marked range,
    //   but the way it actually works is that it's the current cursor *within*
    //   the marked range.
    // - Uses fontWide to decide to jump 1 or 2 columns per character. First,
    //   this is wrong, as wide texts work just fine even without guifontwide
    //   set. Second, some characters may have length > 1. See MMCoreTextView
    //   which does proper length calculation.
    //

    // This method is called when the input manager wants to pop up an
    // auxiliary window.  The position where this should be is controlled by
    // Vim by sending SetPreEditPositionMsgID so compute a position based on
    // the pre-edit (row,column) pair.
    int col = preEditColumn;
    int row = preEditRow;

    NSFont *theFont = [[textView markedTextAttributes]
                       valueForKey:NSFontAttributeName];
    if (theFont == [textView fontWide]) {
        col += imRange.location * 2;
        if (col >= [textView maxColumns] - 1) {
            row += (col / [textView maxColumns]);
            col = col % 2 ? col % [textView maxColumns] + 1 :
            col % [textView maxColumns];
        }
    } else {
        col += imRange.location;
        if (col >= [textView maxColumns]) {
            row += (col / [textView maxColumns]);
            col = col % [textView maxColumns];
        }
    }

    return [self firstRectForCharacterRange:row column:col length:(int)range.length];
}

- (NSRect)firstRectForCharacterRange:(int)row column:(int)col length:(int)numColumns
{
    NSRect rect = [textView rectForRow:row
                                column:col
                               numRows:1
                            numColumns:numColumns];

    // NOTE: If the text view is flipped then 'rect' has its origin in the top
    // left corner of the rect, but the methods below expect it to be in the
    // lower left corner.  Compensate for this here.
    // TODO: Maybe the above method should always return rects where the origin
    // is in the lower left corner?
    if ([textView isFlipped])
        rect.origin.y += rect.size.height;

    rect.origin = [textView convertPoint:rect.origin toView:nil];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
    rect = [[textView window] convertRectToScreen:rect];
#else
    rect.origin = [[textView window] convertBaseToScreen:rect.origin];
#endif

    return rect;
}

- (void)setImControl:(BOOL)enable
{
    // This flag corresponds to the (negation of the) 'imd' option.  When
    // enabled changes to the input method are detected and forwarded to the
    // backend. We do not forward changes to the input method, instead we let
    // Vim be in complete control.

    if (asciiImSource) {
        CFRelease(asciiImSource);
        asciiImSource = NULL;
    }
    if (lastImSource) {
        CFRelease(lastImSource);
        lastImSource = NULL;
    }
    if (enable) {
        // Save current locale input source for use when IM is active and
        // get an ASCII source for use when IM is deactivated (by Vim).
        asciiImSource = TISCopyCurrentASCIICapableKeyboardInputSource();
        NSString *locale = [[NSLocale currentLocale] localeIdentifier];
        lastImSource = TISCopyInputSourceForLanguage((CFStringRef)locale);
    }

    imControl = enable;
    ASLogDebug(@"IM control %sabled", enable ? "en" : "dis");
}

- (void)activateIm:(BOOL)enable
{
    ASLogDebug(@"Activate IM=%d", enable);

    // HACK: If there is marked text when switching IM it will be inserted as
    // normal text.  To avoid this we abandon the marked text before switching.
    [self abandonMarkedText];

    imState = enable;

    // Enable IM: switch back to input source used when IM was last on
    // Disable IM: switch back to ASCII input source (set in setImControl:)
    TISInputSourceRef ref = enable ? lastImSource : asciiImSource;
    if (ref) {
        ASLogDebug(@"Change input source: %@",
                TISGetInputSourceProperty(ref, kTISPropertyInputSourceID));
        TISSelectInputSource(ref);
    }
}

- (BOOL)useInlineIm
{
#ifdef INCLUDE_OLD_IM_CODE
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    return [ud boolForKey:MMUseInlineImKey];
#else
    return YES;
#endif // INCLUDE_OLD_IM_CODE
}

- (void)checkImState
{
    if (imControl) {
        TISInputSourceRef cur = TISCopyCurrentKeyboardInputSource();
        BOOL state = !KeyboardInputSourcesEqual(asciiImSource, cur);
        BOOL isChanged = !KeyboardInputSourcesEqual(lastImSource, cur);
        if (state && isChanged) {
            // Remember current input source so we can switch back to it
            // when IM is once more enabled.
            ASLogDebug(@"Remember last input source: %@",
                TISGetInputSourceProperty(cur, kTISPropertyInputSourceID));
            if (lastImSource) CFRelease(lastImSource);
            lastImSource = cur;
        } else {
            CFRelease(cur);
        }
        if (imState != state) {
            imState = state;
            int msgid = state ? ActivatedImMsgID : DeactivatedImMsgID;
            [[self vimController] sendMessage:msgid data:nil];
        }
        return;
    }
}

@end // MMTextViewHelper




@implementation MMTextViewHelper (Private)

- (MMWindowController *)windowController
{
    id windowController = [[textView window] windowController];
    if ([windowController isKindOfClass:[MMWindowController class]])
        return (MMWindowController*)windowController;
    return nil;
}

- (MMVimController *)vimController
{
    return [[self windowController] vimController];
}

- (void)doKeyDown:(NSString *)key
{
    if (!currentEvent) {
        ASLogDebug(@"No current event; ignore key");
        return;
    }

    const char *chars = [key UTF8String];
    unsigned length = (unsigned)[key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    unsigned keyCode = [currentEvent keyCode];
    unsigned flags = (unsigned)[currentEvent modifierFlags];

    // The low 16 bits are not used for modifier flags by NSEvent.  Use
    // these bits for custom flags.
    flags &= NSEventModifierFlagDeviceIndependentFlagsMask;
    if ([currentEvent isARepeat])
        flags |= 1;

    NSMutableData *data = [NSMutableData data];
    [data appendBytes:&flags length:sizeof(unsigned)];
    [data appendBytes:&keyCode length:sizeof(unsigned)];
    [data appendBytes:&length length:sizeof(unsigned)];
    if (length > 0)
        [data appendBytes:chars length:length];

    [[self vimController] sendMessage:KeyDownMsgID data:data];
}

- (void)doInsertText:(NSString *)text
{
    unsigned length = (unsigned)[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (0 == length)
        return;

    const char *chars = [text UTF8String];
    unsigned keyCode = 0;
    unsigned flags = 0;

    // HACK! insertText: can be called from outside a keyDown: event in which
    // case currentEvent is nil.  This happens e.g. when the "Special
    // Characters" palette is used to insert text.  In this situation we assume
    // that the key is not a repeat (if there was a palette that did auto
    // repeat of input we might have to rethink this).
    if (currentEvent) {
        // HACK! Keys on the numeric key pad are treated as special keys by Vim
        // so we need to pass on key code and modifier flags in this situation.
        unsigned mods = (unsigned)[currentEvent modifierFlags];
        if (mods & NSEventModifierFlagNumericPad) {
            flags = mods & NSEventModifierFlagDeviceIndependentFlagsMask;
            keyCode = [currentEvent keyCode];
        }

        if ([currentEvent isARepeat])
            flags |= 1;
    }

    NSMutableData *data = [NSMutableData data];
    [data appendBytes:&flags length:sizeof(unsigned)];
    [data appendBytes:&keyCode length:sizeof(unsigned)];
    [data appendBytes:&length length:sizeof(unsigned)];
    [data appendBytes:chars length:length];

    [[self vimController] sendMessage:KeyDownMsgID data:data];
}

- (void)hideMouseCursor
{
    // Check 'mousehide' option
    id mh = [[[self vimController] vimState] objectForKey:@"p_mh"];
    if (mh && ![mh boolValue])
        [NSCursor setHiddenUntilMouseMoves:NO];
    else
        [NSCursor setHiddenUntilMouseMoves:YES];
}

- (void)startDragTimerWithInterval:(NSTimeInterval)t
{
    [NSTimer scheduledTimerWithTimeInterval:t target:self
                                   selector:@selector(dragTimerFired:)
                                   userInfo:nil repeats:NO];
}

- (void)dragTimerFired:(NSTimer *)timer
{
    // TODO: Autoscroll in horizontal direction?
    static unsigned tick = 1;

    isAutoscrolling = NO;

    if (isDragging && (dragRow < 0 || dragRow >= [textView maxRows])) {
        // HACK! If the mouse cursor is outside the text area, then send a
        // dragged event.  However, if row&col hasn't changed since the last
        // dragged event, Vim won't do anything (see gui_send_mouse_event()).
        // Thus we fiddle with the column to make sure something happens.
        int col = dragColumn + (dragRow < 0 ? -(tick % 2) : +(tick % 2));
        NSMutableData *data = [NSMutableData data];

        [data appendBytes:&dragRow length:sizeof(int)];
        [data appendBytes:&col length:sizeof(int)];
        [data appendBytes:&dragFlags length:sizeof(unsigned)];

        [[self vimController] sendMessage:MouseDraggedMsgID data:data];

        isAutoscrolling = YES;
    }

    if (isDragging) {
        // Compute timer interval depending on how far away the mouse cursor is
        // from the text view.
        NSRect rect = [self trackingRect];
        float dy = 0;
        if (dragPoint.y < rect.origin.y) dy = rect.origin.y - dragPoint.y;
        else if (dragPoint.y > NSMaxY(rect)) dy = dragPoint.y - NSMaxY(rect);
        if (dy > MMDragAreaSize) dy = MMDragAreaSize;

        NSTimeInterval t = MMDragTimerMaxInterval -
            dy*(MMDragTimerMaxInterval-MMDragTimerMinInterval)/MMDragAreaSize;

        [self startDragTimerWithInterval:t];
    }

    ++tick;
}

- (void)setCursor
{
    static NSCursor *ibeamCursor = nil;

    if (!ibeamCursor) {
        if (AVAILABLE_MAC_OS(10, 14))
        {
            // macOS 10.14 (Mojave) introduced dark mode, and seems to have
            // added a thick white border around the system I-beam cursor,
            // which makes it legible across bright and dark background. Just
            // use it.
            ibeamCursor = [NSCursor IBeamCursor];
        }
        else
        {
            // Pre-Mojave versions the I-beam cursors doesn't have the strong
            // white background and is hard to read on dark background. Use a
            // custom I-beam cursor that has better contrast against dark
            // backgrounds.
            NSImage *ibeamImage = [NSImage imageNamed:@"ibeam"];
            if (ibeamImage) {
                NSSize size = [ibeamImage size];
                NSPoint hotSpot = { size.width*.5f, size.height*.5f };
                
                ibeamCursor = [[NSCursor alloc]
                               initWithImage:ibeamImage hotSpot:hotSpot];
            }
            if (!ibeamCursor) {
                ASLogWarn(@"Failed to load custom Ibeam cursor");
                ibeamCursor = [NSCursor IBeamCursor];
            }
        }
    }

    // This switch should match mshape_names[] in misc2.c.
    //
    // We don't fill every shape here. Only the ones that make sense and have
    // system native cursors to choose from (unless we ship custom cursors).
    switch (mouseShape) {
        case 0: //arrow
            [[NSCursor arrowCursor] set]; break;
        //case 1: // blank
        case 2: // beam
            [ibeamCursor set]; break;
        case 3: // updown
        case 4: // udsizing
            [[NSCursor resizeUpDownCursor] set]; break;
        case 5: // leftright
        case 6: // lrsizing
            [[NSCursor resizeLeftRightCursor] set]; break;
        //case 7: // busy
            // This could be implemented using _coreCursorType override on NSCursor.
            // See WebKit / Chrome / GDK implementation.
        case 8: // no
            [[NSCursor operationNotAllowedCursor] set]; break;
        case 9: // crosshair
            [[NSCursor crosshairCursor] set]; break;
        case 10: // hand1
            [[NSCursor pointingHandCursor] set]; break;
        case 11: // hand2
            [[NSCursor openHandCursor] set]; break;
        //case 12: // pencil
        //case 13: // question
        //case 14: // right-arrow
        //case 15: // up-arrow
        default:
            [[NSCursor arrowCursor] set]; break;
    }

    // Shape 1 indicates that the mouse cursor should be hidden.
    if (1 == mouseShape)
        [NSCursor setHiddenUntilMouseMoves:YES];
}

- (NSRect)trackingRect
{
    NSRect rect = [textView frame];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSUInteger left = [ud integerForKey:MMTextInsetLeftKey];
    NSUInteger top = [ud integerForKey:MMTextInsetTopKey];
    NSUInteger right = [ud integerForKey:MMTextInsetRightKey];
    NSUInteger bot = [ud integerForKey:MMTextInsetBottomKey];

    rect.origin.x = left;
    rect.origin.y = top;
    rect.size.width -= left + right - 1;
    rect.size.height -= top + bot - 1;

    return rect;
}

- (BOOL)inputManagerHandleMouseEvent:(NSEvent *)event
{
    // NOTE: The input manager usually handles events like mouse clicks (e.g.
    // the Kotoeri manager "commits" the text on left clicks).

    if (event) {
        return [[NSTextInputContext currentInputContext] handleEvent:event];
    }

    return NO;
}

- (void)sendMarkedText:(NSString *)text position:(int32_t)pos length:(unsigned)len
{
    if (![self useInlineIm])
        return;

    NSMutableData *data = [NSMutableData data];
    unsigned textlen = text == nil ? 0
                    : (unsigned)[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    [data appendBytes:&textlen length:sizeof(unsigned)];
    [data appendBytes:&pos length:sizeof(int32_t)];
    [data appendBytes:&len length:sizeof(unsigned)];
    if (textlen > 0) {
        [data appendBytes:[text UTF8String] length:textlen];
        [data appendBytes:"\x00" length:1];
    }

    [[self vimController] sendMessage:SetMarkedTextMsgID data:data];
}

- (void)abandonMarkedText
{
    [self unmarkText];

    // Send an empty marked text message with position set to -1 to indicate
    // that the marked text should be abandoned.  (If pos is set to 0 Vim will
    // send backspace sequences to delete the old marked text.)
    [self sendMarkedText:nil position:-1 length:0];
    [[NSTextInputContext currentInputContext] discardMarkedText];
}

- (void)sendGestureEvent:(int)gesture flags:(unsigned)flags
{
    NSMutableData *data = [NSMutableData data];

    [data appendBytes:&flags length:sizeof(unsigned)];
    [data appendBytes:&gesture length:sizeof(int)];

    [[self vimController] sendMessage:GestureMsgID data:data];
}

@end // MMTextViewHelper (Private)
