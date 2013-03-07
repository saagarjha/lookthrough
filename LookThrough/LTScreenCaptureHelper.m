/**
 * Tae Won Ha
 * http://qvacua.com
 * https://github.com/qvacua
 *
 * See LICENSE
 */

#import "LTScreenCaptureHelper.h"
#import "LTLog.h"

/**
* The most of this class consists of
* https://developer.apple.com/library/mac/#samplecode/SonOfGrab/Listings/Controller_m.html
*/

typedef struct {
    // Where to add window information
    NSMutableArray *outputArray;
    // Tracks the index of the window when first inserted
    // so that we can always request that the windows be drawn in order.
    int order;
} WindowListApplierData;

NSString *kAppNameKey = @"applicationName"; // Application Name & PID
NSString *kWindowOriginKey = @"windowOrigin";   // Window Origin as a string
NSString *kWindowSizeKey = @"windowSize";       // Window Size as a string
NSString *kWindowIDKey = @"windowID";           // Window ID
NSString *kWindowLevelKey = @"windowLevel"; // Window Level
NSString *kWindowOrderKey = @"windowOrder"; // The overall front-to-back ordering of the windows as returned by the window server

static uint32_t ChangeBits(uint32_t currentBits, uint32_t flagsToChange, BOOL setFlags) {
    if (setFlags) {    // Set Bits
        return currentBits | flagsToChange;
    } else {    // Clear Bits
        return currentBits & ~flagsToChange;
    }
}

static void WindowListApplierFunction(const void *inputDictionary, void *context) {
    NSDictionary *entry = (NSDictionary *) inputDictionary;
    WindowListApplierData *data = (WindowListApplierData *) context;

    // The flags that we pass to CGWindowListCopyWindowInfo will automatically filter out most undesirable windows.
    // However, it is possible that we will get back a window that we cannot read from, so we'll filter those out manually.
    int sharingState = [[entry objectForKey:(id) kCGWindowSharingState] intValue];
    if (sharingState != kCGWindowSharingNone) {
        NSMutableDictionary *outputEntry = [NSMutableDictionary dictionary];

        // Grab the application name, but since it's optional we need to check before we can use it.
        NSString *applicationName = [entry objectForKey:(id) kCGWindowOwnerName];
        if (applicationName != NULL) {
            // PID is required so we assume it's present.
            NSString *nameAndPID = [NSString stringWithFormat:@"%@ (%@)", applicationName, [entry objectForKey:(id) kCGWindowOwnerPID]];
            [outputEntry setObject:nameAndPID forKey:kAppNameKey];
        }
        else {
            // The application name was not provided, so we use a fake application name to designate this.
            // PID is required so we assume it's present.
            NSString *nameAndPID = [NSString stringWithFormat:@"((unknown)) (%@)", [entry objectForKey:(id) kCGWindowOwnerPID]];
            [outputEntry setObject:nameAndPID forKey:kAppNameKey];
        }

        // Grab the Window Bounds, it's a dictionary in the array, but we want to display it as a string
        CGRect bounds;
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef) [entry objectForKey:(id) kCGWindowBounds], &bounds);
        NSString *originString = [NSString stringWithFormat:@"%.0f/%.0f", bounds.origin.x, bounds.origin.y];
        [outputEntry setObject:originString forKey:kWindowOriginKey];
        NSString *sizeString = [NSString stringWithFormat:@"%.0f*%.0f", bounds.size.width, bounds.size.height];
        [outputEntry setObject:sizeString forKey:kWindowSizeKey];

        // Grab the Window ID & Window Level. Both are required, so just copy from one to the other
        [outputEntry setObject:[entry objectForKey:(id) kCGWindowNumber] forKey:kWindowIDKey];
        [outputEntry setObject:[entry objectForKey:(id) kCGWindowLayer] forKey:kWindowLevelKey];

        // Finally, we are passed the windows in order from front to back by the window server
        // Should the user sort the window list we want to retain that order so that screen shots
        // look correct no matter what selection they make, or what order the items are in. We do this
        // by maintaining a window order key that we'll apply later.
        [outputEntry setObject:[NSNumber numberWithInt:data->order] forKey:kWindowOrderKey];
        data->order++;

        [data->outputArray addObject:outputEntry];
    }
}

static NSString *const qLoginWindowAppName = @"loginwindow";
static NSString *const qScreenSaverAppName = @"ScreenSaverEngine";

@implementation LTScreenCaptureHelper {
    CGWindowListOption listOptions;
    CGWindowListOption singleWindowListOptions;
    CGWindowImageOption imageOptions;
    CGRect imageBounds;

    NSMutableArray *windowArray;
}


- (id)init {
    self = [super init];
    if (self) {
        imageOptions = kCGWindowImageDefault;
        listOptions = ChangeBits(listOptions, kCGWindowListExcludeDesktopElements, NO);
        listOptions = ChangeBits(listOptions, kCGWindowListOptionOnScreenOnly, YES);
        singleWindowListOptions = kCGWindowListOptionOnScreenBelowWindow;
        imageBounds = CGRectInfinite;
    }

    return self;
}

- (NSImage *)screenAsImage {
    [self updateWindowList];

    log4Debug(@"window infos: %@", windowArray);

    __block CGWindowID bottomIrrelevantWindowId;
    __block NSInteger maxWindowLevel = -1;
    [windowArray enumerateObjectsUsingBlock:^(NSDictionary *windowInfo, NSUInteger index, BOOL *stop) {
        NSString *appName = windowInfo[kAppNameKey];
        NSInteger windowLevel = [windowInfo[kWindowLevelKey] integerValue];

        NSRange loginWindowNameRange = [appName rangeOfString:qLoginWindowAppName];
        NSRange screenSaverNameRange = [appName rangeOfString:qScreenSaverAppName];

        if (loginWindowNameRange.location == NSNotFound && screenSaverNameRange.location == NSNotFound) {
            return;
        }

        if (windowLevel > maxWindowLevel) {
            maxWindowLevel = windowLevel;
            bottomIrrelevantWindowId = (CGWindowID) [windowInfo[kWindowIDKey] intValue];
        }
    }];

    log4Debug(@"capturing below the window id (excluded): %@", @(bottomIrrelevantWindowId));

    return [self everythingBelowImage:bottomIrrelevantWindowId];
}

- (void)updateWindowList {
    // Ask the window server for the list of windows.
    CFArrayRef windowList = CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID);

    // Copy the returned list, further pruned, to another list. This also adds some bookkeeping
    // information to the list as well as
    windowArray = [NSMutableArray array];
    WindowListApplierData data = {windowArray, 0};
    CFArrayApplyFunction(windowList, CFRangeMake(0, CFArrayGetCount(windowList)), &WindowListApplierFunction, &data);
    CFRelease(windowList);
}

- (NSImage *)everythingBelowImage:(CGWindowID)windowID {
    // Create an image from the passed in windowID with the single window option selected by the user.
    CGImageRef windowImage = CGWindowListCreateImage(imageBounds, singleWindowListOptions, windowID, imageOptions);
    NSImage *image = [[self imageFromCGImageRef:windowImage] retain];
    CGImageRelease(windowImage);

    return [image autorelease];
}

- (NSImage *)imageFromCGImageRef:(CGImageRef)cgImage {
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];

#ifdef DEBUG
    NSData *data = [bitmapRep representationUsingType:NSPNGFileType properties:nil];
    [data writeToFile:@"/tmp/LookThroughDebugImage.png" atomically:NO];
#endif

    NSImage *image = [[NSImage alloc] init];
    [image addRepresentation:bitmapRep];
    [bitmapRep release];

    return [image autorelease];
}

@end