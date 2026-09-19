#import <AppKit/AppKit.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *dest = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"build/AppIcon.icns";
        NSString *iconsetDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"MacShade.iconset"];
        [NSFileManager.defaultManager removeItemAtPath:iconsetDir error:nil];
        [NSFileManager.defaultManager createDirectoryAtPath:iconsetDir withIntermediateDirectories:YES attributes:nil error:nil];
        
        NSArray<NSNumber *> *sizes = @[@16, @32, @64, @128, @256, @512, @1024];
        
        for (NSNumber *sz in sizes) {
            NSInteger size = [sz integerValue];
            NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
            [img lockFocus];
            
            NSRect bounds = NSMakeRect(0, 0, size, size);
            // Draw background circle with subtle margin
            CGFloat inset = size * 0.04;
            NSRect circleRect = NSInsetRect(bounds, inset, inset);
            NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:circleRect];
            
            // Dark elegant background
            [[NSColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:1.0] setFill];
            [circle fill];
            
            // Vibrant cyan/teal border
            [[NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0] setStroke];
            circle.lineWidth = MAX(1.0, size * 0.04);
            [circle stroke];
            
            // Inner subtle ring
            NSBezierPath *inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circleRect, size * 0.05, size * 0.05)];
            [[NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:0.25] setStroke];
            inner.lineWidth = MAX(1.0, size * 0.02);
            [inner stroke];
            
            // 'M' Monogram
            NSString *m = @"M";
            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:size * 0.46 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0]
            };
            NSSize strSize = [m sizeWithAttributes:attrs];
            NSRect tr = NSMakeRect(
                bounds.origin.x + (bounds.size.width - strSize.width) * 0.5,
                bounds.origin.y + (bounds.size.height - strSize.height) * 0.5 - (size * 0.02),
                strSize.width, strSize.height
            );
            [m drawInRect:tr withAttributes:attrs];
            
            [img unlockFocus];
            
            CGImageRef cgRef = [img CGImageForProposedRect:NULL context:nil hints:nil];
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
            NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            
            // Write standard sizes for iconset
            if (size <= 512) {
                NSString *name = [NSString stringWithFormat:@"icon_%ldx%ld.png", (long)size, (long)size];
                [pngData writeToFile:[iconsetDir stringByAppendingPathComponent:name] atomically:YES];
            }
            if (size >= 32) {
                NSInteger half = size / 2;
                NSString *name2x = [NSString stringWithFormat:@"icon_%ldx%ld@2x.png", (long)half, (long)half];
                [pngData writeToFile:[iconsetDir stringByAppendingPathComponent:name2x] atomically:YES];
            }
        }
        
        NSTask *task = [NSTask new];
        task.launchPath = @"/usr/bin/iconutil";
        task.arguments = @[@"-c", @"icns", iconsetDir, @"-o", dest];
        [task launch];
        [task waitUntilExit];
        [NSFileManager.defaultManager removeItemAtPath:iconsetDir error:nil];
        printf("Created %s\n", dest.UTF8String);
    }
    return 0;
}
