// gen_icon.m — 程序化绘制应用图标并输出多尺寸 PNG（供 iconutil 打包 icns）
// 设计：蓝色渐变圆角方块 + 白色文档 + 绿色加号，呼应"右键新建文件"主题
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

static void renderSize(NSUInteger px, NSString *outPath)
{
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(px, px)];
    [img lockFocus];

    CGFloat S = (CGFloat)px;
    // macOS 图标留 10% 边距的圆角方块
    CGFloat m = S * 0.10;
    CGFloat w = S - 2 * m;
    CGFloat r = w * 0.22;

    // 背景圆角方块：垂直渐变
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(m, m, w, w) xRadius:r yRadius:r];
    NSGradient *grad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.36 green:0.60 blue:0.98 alpha:1.0]
                                                     endingColor:[NSColor colorWithSRGBRed:0.16 green:0.38 blue:0.85 alpha:1.0]];
    [grad drawInBezierPath:bg angle:90.0];

    // 白色文档（居中偏上）
    CGFloat dw = w * 0.46, dh = w * 0.60;
    CGFloat dx = (S - dw) / 2.0;
    CGFloat dy = m + (w - dh) / 2.0 + w * 0.05; // 在圆角方块内垂直居中并略微上移
    CGFloat fold = dw * 0.28;
    NSBezierPath *doc = [NSBezierPath bezierPath];
    [doc moveToPoint:NSMakePoint(dx, dy)];
    [doc lineToPoint:NSMakePoint(dx + dw - fold, dy)];
    [doc lineToPoint:NSMakePoint(dx + dw, dy - fold)]; // 注意：macOS 坐标系 y 向上，折角在右上
    [doc lineToPoint:NSMakePoint(dx + dw, dy + dh)];
    [doc lineToPoint:NSMakePoint(dx, dy + dh)];
    [doc closePath];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.96] setFill];
    [doc fill];

    // 折角三角形（稍暗，营造折叠感）
    NSBezierPath *foldPath = [NSBezierPath bezierPath];
    [foldPath moveToPoint:NSMakePoint(dx + dw - fold, dy)];
    [foldPath lineToPoint:NSMakePoint(dx + dw, dy - fold)];
    [foldPath lineToPoint:NSMakePoint(dx + dw - fold, dy - fold)];
    [foldPath closePath];
    [[NSColor colorWithSRGBRed:0.78 green:0.84 blue:0.94 alpha:1.0] setFill];
    [foldPath fill];

    // 文档上的三行灰色横线（文字示意）
    NSColor *lineC = [NSColor colorWithSRGBRed:0.65 green:0.70 blue:0.78 alpha:1.0];
    CGFloat lw = dw * 0.62, lx = dx + dw * 0.15;
    CGFloat ly = dy + dh * 0.62;
    for (int i = 0; i < 3; i++) {
        NSRect line = NSMakeRect(lx, ly - i * dh * 0.18, lw, MAX(1.5, dh * 0.045));
        NSBezierPath *lp = [NSBezierPath bezierPathWithRoundedRect:line xRadius:line.size.height/2 yRadius:line.size.height/2];
        [lineC setFill];
        [lp fill];
    }

    // 右下角绿色加号圆
    CGFloat cr = w * 0.17;
    CGFloat cx = m + w - cr - w * 0.06;
    CGFloat cy = m + cr + w * 0.06;
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - cr, cy - cr, cr * 2, cr * 2)];
    NSGradient *cg = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.30 green:0.85 blue:0.45 alpha:1.0]
                                                   endingColor:[NSColor colorWithSRGBRed:0.12 green:0.62 blue:0.30 alpha:1.0]];
    [cg drawInBezierPath:circle angle:90.0];
    // 白色加号
    CGFloat bar = cr * 0.62, thick = cr * 0.24;
    [[NSColor whiteColor] setFill];
    [NSBezierPath fillRect:NSMakeRect(cx - bar/2, cy - thick/2, bar, thick)];
    [NSBezierPath fillRect:NSMakeRect(cx - thick/2, cy - bar/2, thick, bar)];

    [img unlockFocus];

    // 导出 PNG（含 Retina 缩放质量）
    NSBitmapImageRep *rep = nil;
    for (NSImageRep *candidate in img.representations) {
        if ([candidate isKindOfClass:[NSBitmapImageRep class]]) { rep = (NSBitmapImageRep *)candidate; break; }
    }
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png) {
        // 兜底：用 CG 渲染
        NSUInteger W = px, H = px;
        unsigned char *data = (unsigned char *)calloc(W * H * 4, 1);
        NSBitmapImageRep *r2 = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&data
                                                                       pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                    colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
        [r2 setSize:NSMakeSize(px, px)];
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:r2];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = ctx;
        [img drawInRect:NSMakeRect(0, 0, px, px)];
        [NSGraphicsContext restoreGraphicsState];
        png = [r2 representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        free(data);
    }
    [png writeToFile:outPath atomically:YES];
    printf("  %s (%lu bytes)\n", outPath.UTF8String, (unsigned long)png.length);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *dir = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"/tmp/appicon.iconset";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        struct { NSString *name; NSUInteger px; } sizes[] = {
            {@"icon_16x16.png", 16}, {@"icon_16x16@2x.png", 32},
            {@"icon_32x32.png", 32}, {@"icon_32x32@2x.png", 64},
            {@"icon_128x128.png", 128}, {@"icon_128x128@2x.png", 256},
            {@"icon_256x256.png", 256}, {@"icon_256x256@2x.png", 512},
            {@"icon_512x512.png", 512}, {@"icon_512x512@2x.png", 1024},
        };
        for (NSUInteger i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++)
            renderSize(sizes[i].px, [dir stringByAppendingPathComponent:sizes[i].name]);
    }
    return 0;
}
