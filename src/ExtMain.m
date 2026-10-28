// ExtMain.m — Finder Sync 扩展主体 v3
// 右键菜单：新建文件 / 打开终端 / 复制路径 / 切换隐藏文件
// v3 变更：
//   - 诊断日志改为直接写容器内 tmp/rc_log.txt（沙箱内必定可写，绕开 NSTask 限制）
//   - 所有需要出沙箱的操作改走 NSUserScriptTask：
//     扩展把命令写进容器 tmp/rc_cmd.sh，调用 Application Scripts/helper.sh 执行
//     （helper.sh 以普通用户权限运行、不受沙箱限制）
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <FinderSync/FinderSync.h>

#define EXT_BUNDLE_ID @"com.user.rightclicktools.RightClickToolsExt"
#ifndef USER_HOME
#define USER_HOME "/Users/apricity"
#endif

#pragma mark - 诊断日志（写扩展容器，外部可读：~/Library/Containers/<id>/Data/tmp/rc_log.txt）

#pragma mark - 功能开关配置（管理台写入，扩展每次右键时读一次；无轮询、零后台开销）

// 宿主（无沙箱）写入 ~/Library/Containers/<id>/Data/Library/Application Support/features.plist
// 扩展（沙箱内 NSHomeDirectory=容器 Data）直接读同一路径
static NSString *FeatureConfigPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/features.plist"];
}

// 诊断日志总开关（管理台里控制，默认关；写日志前先查此标志，关闭时零开销）
static BOOL gLogging = NO;

// 返回某功能是否启用（key: newFile/terminal/copyPath/toggleHidden/copyName/
// verifyHash/openVSCode/openTypora/logging/txt/md/docx/xlsx/pptx）
static BOOL featureEnabled(NSString *key)
{
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:FeatureConfigPath()];
    NSNumber *v = cfg[key];
    return v ? v.boolValue : [key isEqualToString:@"logging"] ? NO : YES;
}

// 日志超过 256KB 时自动截断保留尾部（每次右键建菜单时检查一次，开销可忽略）
static void trimLogIfNeeded(void)
{
    if (!gLogging) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/rc_log.txt"];
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long sz = attr.fileSize;
    if (sz < 256 * 1024) return;
    NSString *whole = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (whole.length > 60000)
        whole = [whole substringFromIndex:whole.length - 60000];
    [whole writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void rcLog(NSString *msg)
{
    if (!gLogging) return; // 日志关闭时直接返回（调试开关）
    @autoreleasepool {
        NSString *tmpDir = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"];
        [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:
                            [tmpDir stringByAppendingPathComponent:@"rc_log.txt"]];
        if (!fh) {
            [line writeToFile:[tmpDir stringByAppendingPathComponent:@"rc_log.txt"]
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

#pragma mark - shell 引用工具

static NSString *shq(NSString *s)
{
    return [NSString stringWithFormat:@"'%@'",
            [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

@interface RightClickSync : FIFinderSync
@end

@implementation RightClickSync
{
    NSDictionary *_newFileDefs;   // ext -> 显示名
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [FIFinderSyncController defaultController].directoryURLs =
            [NSSet setWithObject:[NSURL fileURLWithPath:@"/"]];

        _newFileDefs = @{
            @"txt"  : @"新建文本文档",
            @"md"   : @"新建文档",
            @"docx" : @"新建Word文档",
            @"xlsx" : @"新建Excel表格",
            @"pptx" : @"新建PPT演示文稿",
        };
        gLogging = featureEnabled(@"logging");
        rcLog(@"[init] 扩展启动（v6 开关管理版）");
    }
    return self;
}

#pragma mark - NSUserScriptTask 执行器

// 把命令写进容器 tmp/rc_cmd.sh，再通过 helper.sh（沙箱外）执行
- (void)runOutOfSandbox:(NSString *)shellCommands label:(NSString *)label
{
    NSString *tmpDir = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"];
    NSString *cmdPath = [tmpDir stringByAppendingPathComponent:@"rc_cmd.sh"];
    [shellCommands writeToFile:cmdPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // helper.sh 的两个候选位置：容器内映射路径 / 真实用户目录
    NSArray<NSString *> *candidates = @[
        [NSHomeDirectory() stringByAppendingPathComponent:
         @"Library/Application Scripts/" EXT_BUNDLE_ID @"/helper.sh"],
        @USER_HOME @"/Library/Application Scripts/" EXT_BUNDLE_ID @"/helper.sh",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *helperPath = nil;
    for (NSString *p in candidates) {
        if ([fm fileExistsAtPath:p]) { helperPath = p; break; }
    }
    if (!helperPath) {
        rcLog([NSString stringWithFormat:@"[%@] 找不到 helper.sh，候选: %@", label, candidates]);
        return;
    }

    NSError *err = nil;
    NSUserScriptTask *task = [[NSUserScriptTask alloc] initWithURL:[NSURL fileURLWithPath:helperPath]
                                                             error:&err];
    if (!task) {
        rcLog([NSString stringWithFormat:@"[%@] NSUserScriptTask 创建失败: %@", label, err]);
        return;
    }
    rcLog([NSString stringWithFormat:@"[%@] 通过 helper.sh 执行…", label]);
    [task executeWithCompletionHandler:^(NSError *e) {
        rcLog([NSString stringWithFormat:@"[%@] helper 完成 err=%@", label, e ?: @"无"]);
    }];
}

#pragma mark - 图标

+ (NSImage *)letterIcon:(NSString *)letter color:(NSColor *)color
{
    // 图标缓存：同一字母+颜色只画一次，右键建菜单时零重绘开销
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key = letter;
    NSImage *cached = cache[key];
    if (cached) return cached;

    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [img lockFocus];
    NSBezierPath *rr = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 1.5, 16, 15)
                                                       xRadius:3.5 yRadius:3.5];
    [color setFill];
    [rr fill];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:10.5],
        NSForegroundColorAttributeName: [NSColor whiteColor],
    };
    NSSize tsz = [letter sizeWithAttributes:attrs];
    [letter drawAtPoint:NSMakePoint(roundf((18 - tsz.width) / 2), roundf((18 - tsz.height) / 2) + 1)
         withAttributes:attrs];
    [img unlockFocus];
    cache[key] = img;
    return img;
}

+ (NSImage *)symbolIcon:(NSString *)symbolName
{
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName
                                accessibilityDescription:nil];
    if (!img) return nil;
    NSImage *sized = [[NSImage alloc] initWithSize:NSMakeSize(17, 17)];
    [sized lockFocus];
    [img drawInRect:NSMakeRect(0.5, 0.5, 16, 16)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0];
    [sized unlockFocus];
    sized.template = YES;
    return sized;
}

// 检测应用是否安装（结果缓存，只查一次）
+ (BOOL)appInstalled:(NSString *)bundleID
{
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSNumber *cached = cache[bundleID];
    if (cached) return cached.boolValue;
    NSURL *app = [[NSWorkspace sharedWorkspace]
                  URLForApplicationWithBundleIdentifier:bundleID];
    BOOL ok = (app != nil);
    cache[bundleID] = @(ok);
    return ok;
}

#pragma mark - 菜单

- (NSMenuItem *)item:(NSString *)title action:(SEL)a icon:(NSImage *)icon
{
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:a keyEquivalent:@""];
    it.target = self;
    it.image  = icon;
    return it;
}

- (NSMenu *)menuForMenuKind:(FIMenuKind)kind
{
    if (kind == FIMenuKindContextualMenuForSidebar) return nil;

    // 每次右键：刷新日志开关 + 防膨胀截断（仅此两次轻量操作，无后台开销）
    gLogging = featureEnabled(@"logging");
    trimLogIfNeeded();

    FIFinderSyncController *c = [FIFinderSyncController defaultController];
    rcLog([NSString stringWithFormat:@"[menu] kind=%ld targeted=%@ selected=%@",
           (long)kind, c.targetedURL.path, c.selectedItemURLs]);

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"右键工具箱"];
    menu.autoenablesItems = NO;

    // —— 新建文件 子菜单（按功能开关过滤；不加分隔符：Finder 把分隔符渲染成空白行） ——
    NSMenu *newMenu = [[NSMenu alloc] initWithTitle:@"新建文件"];
    newMenu.autoenablesItems = NO;
    NSDictionary<NSString *, NSNumber *> *extTags = @{
        @"txt": @0, @"md": @1, @"docx": @2, @"xlsx": @3, @"pptx": @4 };
    for (NSString *ext in [_newFileDefs keysSortedByValueUsingSelector:@selector(compare:)]) {
        if (!featureEnabled(ext)) continue;
        NSString *letter = nil;
        NSColor *color = nil;
        if ([ext isEqualToString:@"docx"])      { letter = @"W"; color = [NSColor colorWithSRGBRed:0.18 green:0.42 blue:0.78 alpha:1]; }
        else if ([ext isEqualToString:@"xlsx"]) { letter = @"X"; color = [NSColor colorWithSRGBRed:0.12 green:0.60 blue:0.32 alpha:1]; }
        else if ([ext isEqualToString:@"pptx"]) { letter = @"P"; color = [NSColor colorWithSRGBRed:0.86 green:0.44 blue:0.10 alpha:1]; }
        else if ([ext isEqualToString:@"txt"])  { letter = @"T"; color = [NSColor colorWithSRGBRed:0.45 green:0.47 blue:0.50 alpha:1]; }
        else if ([ext isEqualToString:@"md"])   { letter = @"M"; color = [NSColor colorWithSRGBRed:0.52 green:0.36 blue:0.76 alpha:1]; }
        NSImage *icon = letter ? [RightClickSync letterIcon:letter color:color] : nil;

        NSMenuItem *it = [self item:[NSString stringWithFormat:@"%@.%@", _newFileDefs[ext], ext]
                             action:@selector(newFile:)
                               icon:icon];
        it.representedObject = ext;
        it.tag = extTags[ext].integerValue;
        [newMenu addItem:it];
    }
    if (featureEnabled(@"newFile") && newMenu.numberOfItems) {
        NSMenuItem *newSub = [[NSMenuItem alloc] initWithTitle:@"新建文件"
                                                        action:nil keyEquivalent:@""];
        newSub.image = [RightClickSync symbolIcon:@"doc.badge.plus"];
        newSub.submenu = newMenu;
        [menu addItem:newSub];
    }

    // —— 其余功能项（按功能开关过滤） ——
    if (featureEnabled(@"terminal"))
        [menu addItem:[self item:@"在此处打开终端" action:@selector(openTerminal:)
                            icon:[RightClickSync symbolIcon:@"terminal"]]];
    if (featureEnabled(@"copyPath"))
        [menu addItem:[self item:@"复制文件路径" action:@selector(copyPath:)
                            icon:[RightClickSync symbolIcon:@"doc.on.doc"]]];
    if (featureEnabled(@"copyName"))
        [menu addItem:[self item:@"复制文件名" action:@selector(copyName:)
                            icon:[RightClickSync symbolIcon:@"doc.plaintext"]]];
    if (featureEnabled(@"verifyHash"))
        [menu addItem:[self item:@"复制 MD5/SHA256 校验值" action:@selector(verifyHash:)
                            icon:[RightClickSync symbolIcon:@"number"]]];
    if (featureEnabled(@"openVSCode") && [RightClickSync appInstalled:@"com.microsoft.VSCode"])
        [menu addItem:[self item:@"用 VS Code 打开" action:@selector(openVSCode:)
                            icon:[RightClickSync symbolIcon:@"chevron.left.forwardslash.chevron.right"]]];
    if (featureEnabled(@"openTypora") && [RightClickSync appInstalled:@"abnerworks.typora"])
        [menu addItem:[self item:@"用 Typora 打开" action:@selector(openTypora:)
                            icon:[RightClickSync symbolIcon:@"text.alignleft"]]];
    if (featureEnabled(@"toggleHidden"))
        [menu addItem:[self item:[self hiddenToggleTitle] action:@selector(toggleHiddenFiles:)
                            icon:[RightClickSync symbolIcon:@"eye"]]];
    if (!menu.numberOfItems) return nil; // 全部关闭时不注入任何菜单项
    return menu;
}

#pragma mark - 目标目录

// Finder 给的常是 file-id 引用 URL（/.file/id=...），先解析成真实路径 URL
+ (NSURL *)resolveURL:(NSURL *)url
{
    if (!url) return nil;
    if (url.isFileReferenceURL) {
        NSURL *p = url.filePathURL;
        if (p) return p;
    }
    return url;
}

- (NSURL *)targetDir
{
    FIFinderSyncController *c = [FIFinderSyncController defaultController];
    NSArray<NSURL *> *sel = c.selectedItemURLs;
    if (sel.count >= 1) {
        NSURL *u = [RightClickSync resolveURL:sel[0]];
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:u.path isDirectory:&isDir];
        if (isDir) return u;
    }
    return [RightClickSync resolveURL:c.targetedURL];
}

#pragma mark - 1. 新建文件

- (void)newFile:(NSMenuItem *)sender
{
    // representedObject 在 Finder 菜单合并传递中会丢失，改从标题解析扩展名（tag 作备选）
    NSString *ext = nil;
    NSDictionary<NSString *, NSString *> *tagMap = @{
        @"0": @"txt", @"1": @"md", @"2": @"docx", @"3": @"xlsx", @"4": @"pptx" };
    ext = tagMap[[NSString stringWithFormat:@"%ld", (long)sender.tag]];
    if (!ext) {
        for (NSString *e in @[@"docx", @"xlsx", @"pptx", @"txt", @"md"]) {
            if ([sender.title hasSuffix:[NSString stringWithFormat:@".%@", e]]) { ext = e; break; }
        }
    }
    NSURL *dir = [self targetDir];
    rcLog([NSString stringWithFormat:@"[newFile] title=%@ ext=%@ dir=%@", sender.title, ext, dir.path]);
    if (!ext || !dir) { rcLog(@"[newFile] 缺 ext 或 dir，中止"); return; }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = _newFileDefs[ext] ?: @"新建文件";
    NSString *name = [NSString stringWithFormat:@"%@.%@", base, ext];
    int n = 2;
    while ([fm fileExistsAtPath:[dir URLByAppendingPathComponent:name].path]) {
        name = [NSString stringWithFormat:@"%@ %d.%@", base, n++, ext];
    }
    NSString *dest = [dir URLByAppendingPathComponent:name].path;

    NSMutableString *cmd = [NSMutableString string];

    if ([ext isEqualToString:@"md"]) {
        // 先尝试进程内直写
        NSError *err = nil;
        [@"# 新建文档\n" writeToFile:dest atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (!err) { rcLog(@"[newFile] 直写成功"); }
        else {
            rcLog([NSString stringWithFormat:@"[newFile] 直写失败(%@)，走 helper", err.localizedDescription]);
            [cmd appendFormat:@"printf '%%s\\n' %@ > %@\n", shq(@"# 新建文档"), shq(dest)];
        }
    } else if ([ext isEqualToString:@"txt"]) {
        NSError *err = nil;
        [@"" writeToFile:dest atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (!err) { rcLog(@"[newFile] 直写成功"); }
        else {
            rcLog([NSString stringWithFormat:@"[newFile] 直写失败(%@)，走 helper", err.localizedDescription]);
            [cmd appendFormat:@"touch %@\n", shq(dest)];
        }
    } else {
        NSURL *tpl = [[NSBundle bundleForClass:[self class]]
                      URLForResource:@"blank" withExtension:ext];
        if (!tpl) { rcLog(@"[newFile] 找不到模板！"); return; }
        NSError *err = nil;
        [fm copyItemAtURL:tpl toURL:[NSURL fileURLWithPath:dest] error:&err];
        if (!err) { rcLog(@"[newFile] 模板直拷成功"); }
        else {
            rcLog([NSString stringWithFormat:@"[newFile] 直拷失败(%@)，走 helper", err.localizedDescription]);
            [cmd appendFormat:@"cp -f %@ %@\n", shq(tpl.path), shq(dest)];
        }
    }

    if (cmd.length) {
        [cmd appendFormat:@"/usr/bin/open -R %@\n", shq(dest)];
        [self runOutOfSandbox:cmd label:[NSString stringWithFormat:@"newFile:%@", ext]];
    } else {
        // 直写成功，单独 reveal
        [self runOutOfSandbox:[NSString stringWithFormat:@"/usr/bin/open -R %@\n", shq(dest)]
                        label:@"reveal"];
    }
}

#pragma mark - 2. 打开终端

- (void)openTerminal:(NSMenuItem *)sender
{
    NSURL *dir = [self targetDir];
    rcLog([NSString stringWithFormat:@"[openTerminal] dir=%@", dir.path]);
    if (!dir) return;
    [self runOutOfSandbox:[NSString stringWithFormat:@"/usr/bin/open -a Terminal %@\n",
                           shq(dir.path)]
                    label:@"openTerminal"];
}

#pragma mark - 3. 复制路径

- (void)copyPath:(NSMenuItem *)sender
{
    FIFinderSyncController *c = [FIFinderSyncController defaultController];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    if (c.selectedItemURLs.count) {
        for (NSURL *u in c.selectedItemURLs) {
            NSURL *r = [RightClickSync resolveURL:u];
            if (r) [urls addObject:r];
        }
    }
    else if (c.targetedURL) [urls addObject:[RightClickSync resolveURL:c.targetedURL]];
    rcLog([NSString stringWithFormat:@"[copyPath] urls=%@", urls]);
    if (!urls.count) return;

    NSString *text = [[urls valueForKey:@"path"] componentsJoinedByString:@"\n"];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    BOOL ok = [pb writeObjects:urls];
    [pb setString:text forType:NSPasteboardTypeString];
    rcLog([NSString stringWithFormat:@"[copyPath] 剪贴板直写=%@", ok ? @"OK" : @"FAIL"]);

    if (!ok) {
        // 兜底：helper 里用 pbcopy
        NSMutableString *cmd = [NSMutableString stringWithFormat:@"printf '%%s\\n'"];
        for (NSURL *u in urls) [cmd appendFormat:@" %@", shq(u.path)];
        [cmd appendString:@" | /usr/bin/pbcopy\n"];
        [self runOutOfSandbox:cmd label:@"copyPath"];
    }
}

#pragma mark - 3b. 复制文件名（不含路径）

- (void)copyName:(NSMenuItem *)sender
{
    FIFinderSyncController *c = [FIFinderSyncController defaultController];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (c.selectedItemURLs.count) {
        for (NSURL *u in c.selectedItemURLs) {
            NSURL *r = [RightClickSync resolveURL:u];
            if (r) [names addObject:r.lastPathComponent];
        }
    } else if (c.targetedURL) {
        [names addObject:[RightClickSync resolveURL:c.targetedURL].lastPathComponent];
    }
    rcLog([NSString stringWithFormat:@"[copyName] names=%@", names]);
    if (!names.count) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[names componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

#pragma mark - 3c. MD5 / SHA256 校验值（结果进剪贴板）

- (void)verifyHash:(NSMenuItem *)sender
{
    FIFinderSyncController *c = [FIFinderSyncController defaultController];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    if (c.selectedItemURLs.count) {
        for (NSURL *u in c.selectedItemURLs) {
            NSURL *r = [RightClickSync resolveURL:u];
            if (r) [urls addObject:r];
        }
    } else if (c.targetedURL) {
        [urls addObject:[RightClickSync resolveURL:c.targetedURL]];
    }
    rcLog([NSString stringWithFormat:@"[verifyHash] urls=%@", urls]);
    if (!urls.count) return;

    // 沙箱内读不了选中文件本体，统一交给 helper.sh（普通用户权限）计算后写剪贴板
    // 注意：命令替换里不能再套转义引号（会被当成文件名的一部分传给 md5），
    //      所以先存进变量再 echo，全程只用一层引号
    NSMutableString *cmd = [NSMutableString stringWithString:@"tmpf=$(mktemp)\n"];
    for (NSURL *u in urls) {
        [cmd appendFormat:@"\nf=%@\n", shq(u.path)];
        [cmd appendString:@"n=$(basename \"$f\")\n"];
        [cmd appendString:@"m=$(md5 -q \"$f\")\n"];
        [cmd appendString:@"s=$(shasum -a 256 \"$f\" | awk '{print $1}')\n"];
        [cmd appendString:@"echo \"MD5    ($n): $m\" >> \"$tmpf\"\n"];
        [cmd appendString:@"echo \"SHA256 ($n): $s\" >> \"$tmpf\"\n"];
    }
    [cmd appendString:@"cat \"$tmpf\" | /usr/bin/pbcopy\nrm -f \"$tmpf\"\n"];
    [self runOutOfSandbox:cmd label:@"verifyHash"];
}

#pragma mark - 3d. 用 VS Code / Typora 打开

- (void)openVSCode:(NSMenuItem *)sender { [self openInApp:@"Visual Studio Code" label:@"openVSCode"]; }
- (void)openTypora:(NSMenuItem *)sender { [self openInApp:@"Typora" label:@"openTypora"]; }

- (void)openInApp:(NSString *)app label:(NSString *)label
{
    FIFinderSyncController *c = [FIFinderSyncController defaultController];
    NSMutableString *cmd = [NSMutableString stringWithFormat:@"/usr/bin/open -a %@",
                            shq(app)];
    BOOL any = NO;
    if (c.selectedItemURLs.count) {
        for (NSURL *u in c.selectedItemURLs) {
            NSURL *r = [RightClickSync resolveURL:u];
            if (r) { [cmd appendFormat:@" %@", shq(r.path)]; any = YES; }
        }
    }
    if (!any && c.targetedURL) {
        NSURL *r = [RightClickSync resolveURL:c.targetedURL];
        if (r) [cmd appendFormat:@" %@", shq(r.path)];
    }
    [cmd appendString:@"\n"];
    rcLog([NSString stringWithFormat:@"[%@] cmd=%@", label, cmd]);
    [self runOutOfSandbox:cmd label:label];
}

#pragma mark - 4. 切换隐藏文件

- (BOOL)hiddenFilesShown
{
    CFPreferencesAppSynchronize(CFSTR("com.apple.finder"));
    CFBooleanRef v = CFPreferencesCopyAppValue(CFSTR("AppleShowAllFiles"), CFSTR("com.apple.finder"));
    BOOL shown = v ? CFBooleanGetValue(v) : NO;
    if (v) CFRelease(v);
    return shown;
}

- (NSString *)hiddenToggleTitle
{
    return [self hiddenFilesShown] ? @"隐藏所有隐藏文件" : @"显示所有隐藏文件";
}

- (void)toggleHiddenFiles:(NSMenuItem *)sender
{
    BOOL target = ![self hiddenFilesShown];
    rcLog([NSString stringWithFormat:@"[toggleHidden] target=%@", target ? @"YES" : @"NO"]);

    // 进程内先试（未沙箱时有效）
    CFPreferencesSetAppValue(CFSTR("AppleShowAllFiles"),
                             target ? kCFBooleanTrue : kCFBooleanFalse,
                             CFSTR("com.apple.finder"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.finder"));

    NSMutableString *cmd = [NSMutableString string];
    if ([self hiddenFilesShown] != target) {
        rcLog(@"[toggleHidden] 进程内写入无效，走 helper");
        [cmd appendFormat:@"/usr/bin/defaults write com.apple.finder AppleShowAllFiles -bool %@\n",
         target ? @"YES" : @"NO"];
    } else {
        rcLog(@"[toggleHidden] 进程内写入成功（但仍需重启 Finder）");
    }
    [cmd appendString:@"/usr/bin/killall Finder\n"];
    [self runOutOfSandbox:cmd label:@"toggleHidden"];
}

@end
