// HostMain.m — 宿主 App：管理台 GUI v5（纯手动 Auto Layout，杜绝元素重叠）
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import <FinderSync/FinderSync.h>
#import <sys/stat.h>

#define EXT_BUNDLE_ID @"com.user.rightclicktools.RightClickToolsExt"

#pragma mark - 路径工具

static NSString *ContainerDataPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Containers/" EXT_BUNDLE_ID @"/Data"];
}
static NSString *ConfigPath(void)
{
    return [ContainerDataPath() stringByAppendingPathComponent:
            @"Library/Application Support/features.plist"];
}
static NSString *HelperUserPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Scripts/" EXT_BUNDLE_ID @"/helper.sh"];
}
static NSString *HelperContainerPath(void)
{
    return [ContainerDataPath() stringByAppendingPathComponent:
            @"Library/Application Scripts/" EXT_BUNDLE_ID @"/helper.sh"];
}
static NSString *LogPath(void)
{
    return [ContainerDataPath() stringByAppendingPathComponent:@"tmp/rc_log.txt"];
}
static BOOL fileExistsExec(NSString *p)
{
    struct stat st;
    return p && stat(p.UTF8String, &st) == 0 && (st.st_mode & S_IXUSR);
}

static NSString *runCmd(NSString *launchPath, NSArray<NSString *> *args)
{
    NSTask *t = [NSTask new];
    t.launchPath = launchPath;
    t.arguments = args;
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = out;
    @try {
        [t launch];
        [t waitUntilExit];
        return [[NSString alloc] initWithData:[out.fileHandleForReading readDataToEndOfFile]
                                     encoding:NSUTF8StringEncoding];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"执行失败: %@", e.reason];
    }
}

// 追加一行到共享日志（扩展的 rc_log.txt，管理台日志页直接可见，排查授权问题用）
static void appendLog(NSString *text)
{
    NSString *p = LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:p])
        [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) return;
    [fh seekToEndOfFile];
    NSString *line = [NSString stringWithFormat:@"[管理台 %@] %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
                                       dateStyle:NSDateFormatterNoStyle
                                       timeStyle:NSDateFormatterMediumStyle], text];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#pragma mark - AppDelegate

// 本次启动是否由内部命令 URL 触发（true 时不显示管理台）
static BOOL gURLHandled = NO;

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) NSTextField *statusField;
@property(strong) NSMutableDictionary<NSString *, NSButton *> *switches;
@property(strong) NSPopUpButton *termPopup;
@property(strong) NSTextField *termCustom;
@property(strong) NSTextView *logView;
@property(strong) NSTimer *timer;
@end

@implementation AppDelegate

- (void)installHelper
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *helperSrc = [[NSBundle mainBundle] URLForResource:@"helper" withExtension:@"sh"];
    if (!helperSrc) return;
    for (NSString *dir in @[
        [HelperUserPath() stringByDeletingLastPathComponent],
        [HelperContainerPath() stringByDeletingLastPathComponent],
    ]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dst = [dir stringByAppendingPathComponent:@"helper.sh"];
        [fm removeItemAtPath:dst error:nil];
        [fm copyItemAtPath:helperSrc.path toPath:dst error:nil];
        chmod(dst.UTF8String, 0755);
    }
}

// 终端预设：@[显示名, bundle ID, 菜单里用的短标签]
// 只存 bundle ID——显示名会因语言/别名漂移（iTerm.app 的显示名是 iTerm2），bundle ID 才稳定
+ (NSArray<NSArray *> *)terminalPresets
{
    return @[
        @[@"终端 Terminal", @"com.apple.Terminal",     @"终端"],
        @[@"iTerm2",        @"com.googlecode.iterm2",  @"iTerm2"],
        @[@"Warp",          @"dev.warp.Warp-Stable",   @"Warp"],
        @[@"WezTerm",       @"org.wezfurlong.wezterm", @"WezTerm"],
    ];
}

- (void)saveTerminalConfig
{
    NSMutableDictionary *cfg = [self loadConfig];
    NSArray<NSArray *> *presets = [AppDelegate terminalPresets];
    NSInteger idx = self.termPopup.indexOfSelectedItem;
    NSString *app = nil, *label = nil;
    if (idx >= 0 && idx < (NSInteger)presets.count) {
        app   = presets[idx][1];
        label = presets[idx][2];
    } else { // 自定义：输入框里是 bundle ID
        app = [self.termCustom.stringValue stringByTrimmingCharactersInSet:
               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!app.length) app = @"com.apple.Terminal";
        NSString *tail = [app componentsSeparatedByString:@"."].lastObject;
        label = tail.length ? tail : app;
    }
    cfg[@"terminalApp"] = app;
    cfg[@"terminalAppLabel"] = label;
    [cfg writeToFile:ConfigPath() atomically:YES];
}

- (void)syncTerminalFromConfig
{
    NSDictionary *cfg = [self loadConfig];
    NSString *app = cfg[@"terminalApp"];
    if (!app.length) app = @"com.apple.Terminal";
    NSArray<NSArray *> *presets = [AppDelegate terminalPresets];
    NSInteger idx = (NSInteger)presets.count; // 默认落在"自定义"
    for (NSUInteger i = 0; i < presets.count; i++)
        if ([presets[i][1] isEqualToString:app]) { idx = (NSInteger)i; break; }
    [self.termPopup selectItemAtIndex:idx];
    BOOL custom = (idx == (NSInteger)presets.count);
    self.termCustom.enabled = custom;
    self.termCustom.stringValue = custom ? app : @"";
}

- (void)terminalPopupChanged:(id)sender
{
    NSInteger idx = self.termPopup.indexOfSelectedItem;
    BOOL custom = (idx == (NSInteger)[AppDelegate terminalPresets].count);
    self.termCustom.enabled = custom;
    if (custom) {
        [self.window makeFirstResponder:self.termCustom];
    }
    [self saveTerminalConfig];
}

- (void)terminalCustomChanged:(id)sender
{
    [self saveTerminalConfig];
}

#pragma mark - 配置读写

+ (NSArray<NSArray *> *)featureKeys
{
    // @[显示名, 配置key]——两列网格
    return @[
        @[@"新建文件（子菜单）",   @"newFile"],
        @[@"复制文件名",           @"copyName"],
        @[@"在此处打开终端",       @"terminal"],
        @[@"MD5/SHA256 校验值",    @"verifyHash"],
        @[@"复制文件路径",         @"copyPath"],
        @[@"用 VS Code 打开",      @"openVSCode"],
        @[@"显示/隐藏隐藏文件",    @"toggleHidden"],
        @[@"用 Typora 打开",       @"openTypora"],
        @[@"复制文件信息",         @"copyInfo"],
    ];
}

- (NSMutableDictionary *)loadConfig
{
    NSMutableDictionary *cfg = [[NSMutableDictionary alloc]
        initWithDictionary:[NSDictionary dictionaryWithContentsOfFile:ConfigPath()] ?: @{}];
    for (NSArray *f in [AppDelegate featureKeys]) if (!cfg[f[1]]) cfg[f[1]] = @YES;
    for (NSString *k in @[@"txt", @"md", @"docx", @"xlsx", @"pptx"])
        if (!cfg[k]) cfg[k] = @YES;
    if (!cfg[@"logging"]) cfg[@"logging"] = @NO;
    return cfg;
}

- (void)saveConfig
{
    NSMutableDictionary *cfg = [self loadConfig];
    for (NSString *k in self.switches) cfg[k] = @(self.switches[k].state == NSControlStateValueOn);
    [cfg writeToFile:ConfigPath() atomically:YES];
}

#pragma mark - UI 组件

- (NSButton *)checkbox:(NSString *)title key:(NSString *)key
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    [b setButtonType:NSButtonTypeSwitch];
    b.title = title;
    b.font = [NSFont systemFontOfSize:13];
    b.target = self;
    b.action = @selector(switchChanged:);
    b.translatesAutoresizingMaskIntoConstraints = NO;
    self.switches[key] = b;
    return b;
}

- (NSButton *)pillButton:(NSString *)title action:(SEL)a
{
    NSButton *b = [NSButton buttonWithTitle:title target:self action:a];
    b.bezelStyle = NSBezelStyleRounded;
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:11];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold color:(NSColor *)color
{
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    l.textColor = color ?: [NSColor labelColor];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

// 圆角卡片：标题在顶部，内容占满剩余宽度（全部手动约束，高度由内容决定）
- (NSView *)card:(NSString *)title content:(NSView *)content
{
    NSView *card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.wantsLayer = YES;
    card.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;
    card.layer.cornerRadius = 10.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor separatorColor].CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *t = [self label:title size:12 bold:YES color:[NSColor secondaryLabelColor]];
    [card addSubview:t];
    [card addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [t.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [t.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [t.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-14],

        [content.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:10],
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    ]];
    return card;
}

#pragma mark - UI 布局（手动约束，每个区块钉死相对位置）

- (void)buildUI
{
    self.switches = [NSMutableDictionary dictionary];

    // 先在独立容器里构建内容，最后按内容实际高度创建窗口，
    // 避免"窗口写死高度 + 约束链钉死"导致 Auto Layout 破坏约束、在网格中间撑出空白
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, 660)];

    // ── 头部：图标 + 标题/状态 ──
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iconView.image = [NSApp applicationIconImage];
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *titleL = [self label:@"右键工具箱" size:17 bold:YES color:nil];
    self.statusField = [self label:[self statusText] size:12 bold:NO
                             color:[NSColor secondaryLabelColor]];

    [root addSubview:iconView];
    [root addSubview:titleL];
    [root addSubview:self.statusField];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [iconView.centerYAnchor constraintEqualToAnchor:titleL.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:44],
        [iconView.heightAnchor constraintEqualToConstant:44],

        [titleL.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [titleL.topAnchor constraintEqualToAnchor:root.topAnchor constant:18],

        [self.statusField.leadingAnchor constraintEqualToAnchor:titleL.leadingAnchor],
        [self.statusField.topAnchor constraintEqualToAnchor:titleL.bottomAnchor constant:4],
    ]];

    // ── 卡片 1：右键菜单功能（NSGridView 两列，尺寸自适应文字） ──
    NSArray *feats = [AppDelegate featureKeys];
    NSMutableArray<NSArray<NSView *> *> *gridRows = [NSMutableArray array];
    for (NSUInteger i = 0; i < feats.count; i += 2) {
        NSMutableArray<NSView *> *row = [NSMutableArray array];
        [row addObject:[self checkbox:feats[i][0] key:feats[i][1]]];
        if (i + 1 < feats.count) [row addObject:[self checkbox:feats[i+1][0] key:feats[i+1][1]]];
        [gridRows addObject:row];
    }
    NSGridView *featGrid = [NSGridView gridViewWithViews:gridRows];
    featGrid.rowSpacing = 10;
    featGrid.columnSpacing = 40;
    featGrid.translatesAutoresizingMaskIntoConstraints = NO;

    // ── 终端应用选择（跟在功能开关下方，同一张卡片） ──
    NSTextField *termLabel = [self label:@"终端应用" size:13 bold:NO color:nil];
    self.termPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.termPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.termPopup.controlSize = NSControlSizeSmall;
    self.termPopup.font = [NSFont systemFontOfSize:12];
    self.termPopup.target = self;
    self.termPopup.action = @selector(terminalPopupChanged:);
    for (NSArray *p in [AppDelegate terminalPresets])
        [self.termPopup addItemWithTitle:p[0]];
    [self.termPopup addItemWithTitle:@"自定义…"];

    self.termCustom = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.termCustom.translatesAutoresizingMaskIntoConstraints = NO;
    self.termCustom.controlSize = NSControlSizeSmall;
    self.termCustom.font = [NSFont systemFontOfSize:12];
    self.termCustom.placeholderString = @"Bundle ID，如 dev.warp.Warp-Stable";
    self.termCustom.target = self;
    self.termCustom.action = @selector(terminalCustomChanged:);
    ((NSTextFieldCell *)self.termCustom.cell).sendsActionOnEndEditing = YES; // 失焦即保存

    NSStackView *termRow = [NSStackView stackViewWithViews:@[termLabel, self.termPopup, self.termCustom]];
    termRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    termRow.alignment = NSLayoutAttributeCenterY;
    termRow.spacing = 8;
    termRow.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.termPopup.widthAnchor constraintEqualToConstant:150],
        [self.termCustom.widthAnchor constraintGreaterThanOrEqualToConstant:190],
    ]];

    // 卡片 1 内容 = 功能网格 + 终端行（纵向堆叠，高度仍由内容撑开，交给 fittingSize 量）
    NSStackView *card1Body = [NSStackView stackViewWithViews:@[featGrid, termRow]];
    card1Body.orientation = NSUserInterfaceLayoutOrientationVertical;
    card1Body.alignment = NSLayoutAttributeLeading;
    card1Body.spacing = 12;
    card1Body.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *card1 = [self card:@"右键菜单功能" content:card1Body];
    [root addSubview:card1];

    // ── 卡片 2：新建文件类型（单行网格，列宽自适应，绝不重叠） ──
    NSMutableArray<NSArray<NSView *> *> *typeRow = [NSMutableArray array];
    for (NSArray *ft in @[@[@"文本文档 (.txt)", @"txt"], @[@"Markdown (.md)", @"md"],
                          @[@"Word (.docx)", @"docx"], @[@"Excel (.xlsx)", @"xlsx"],
                          @[@"PPT (.pptx)", @"pptx"]]) {
        [typeRow addObject:[self checkbox:ft[0] key:ft[1]]];
    }
    NSGridView *typeGrid = [NSGridView gridViewWithViews:@[typeRow]];
    typeGrid.rowSpacing = 8;
    typeGrid.columnSpacing = 14;
    typeGrid.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *card2 = [self card:@"新建文件包含的类型" content:typeGrid];
    [root addSubview:card2];

    // ── 卡片 3：诊断日志 ──
    NSButton *logSwitch = [self checkbox:@"记录诊断日志" key:@"logging"];
    NSTextField *logHint = [self label:@"关闭时零开销；开启后自动限 256KB"
                                 size:11 bold:NO color:[NSColor tertiaryLabelColor]];
    NSButton *openLogBtn = [self pillButton:@"打开日志文件夹" action:@selector(openLogFolder)];
    NSButton *clearBtn = [self pillButton:@"清空" action:@selector(clearLog)];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.borderType = NSBezelBorder;
    sv.hasVerticalScroller = YES;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.logView.editable = NO;
    self.logView.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    [sv setDocumentView:self.logView];

    // 日志卡片内容容器：头部行 + 滚动区，全部手动约束
    NSView *logContent = [[NSView alloc] initWithFrame:NSZeroRect];
    logContent.translatesAutoresizingMaskIntoConstraints = NO;
    [logContent addSubview:logSwitch];
    [logContent addSubview:logHint];
    [logContent addSubview:openLogBtn];
    [logContent addSubview:clearBtn];
    [logContent addSubview:sv];
    [NSLayoutConstraint activateConstraints:@[
        [logSwitch.topAnchor constraintEqualToAnchor:logContent.topAnchor],
        [logSwitch.leadingAnchor constraintEqualToAnchor:logContent.leadingAnchor],

        [clearBtn.centerYAnchor constraintEqualToAnchor:logSwitch.centerYAnchor],
        [clearBtn.trailingAnchor constraintEqualToAnchor:logContent.trailingAnchor],
        [openLogBtn.centerYAnchor constraintEqualToAnchor:logSwitch.centerYAnchor],
        [openLogBtn.trailingAnchor constraintEqualToAnchor:clearBtn.leadingAnchor constant:-10],

        [logHint.centerYAnchor constraintEqualToAnchor:logSwitch.centerYAnchor],
        [logHint.leadingAnchor constraintGreaterThanOrEqualToAnchor:logSwitch.trailingAnchor constant:16],
        [logHint.trailingAnchor constraintLessThanOrEqualToAnchor:openLogBtn.leadingAnchor constant:-12],

        [sv.topAnchor constraintEqualToAnchor:logSwitch.bottomAnchor constant:10],
        [sv.leadingAnchor constraintEqualToAnchor:logContent.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:logContent.trailingAnchor],
        [sv.heightAnchor constraintEqualToConstant:210],
        [logContent.bottomAnchor constraintEqualToAnchor:sv.bottomAnchor],
    ]];
    NSView *card3 = [self card:@"诊断日志（调试用，默认关闭）" content:logContent];
    [root addSubview:card3];

    // ── 底部按钮 ──
    NSMutableArray<NSButton *> *btns = [NSMutableArray array];
    for (NSArray *b in @[@[@"打开扩展设置", @"openExtSettings"],
                         @[@"切换隐藏文件", @"toggleHidden"],
                         @[@"重装功能脚本", @"reinstallHelper"]]) {
        NSButton *btn = [NSButton buttonWithTitle:b[0] target:self action:NSSelectorFromString(b[1])];
        btn.bezelStyle = NSBezelStyleRounded;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btns addObject:btn];
    }

    // ── 纵向串联所有区块 ──
    NSMutableArray *cons = [NSMutableArray array];
    [cons addObjectsFromArray:@[
        [card1.topAnchor constraintEqualToAnchor:self.statusField.bottomAnchor constant:16],
        [card2.topAnchor constraintEqualToAnchor:card1.bottomAnchor constant:14],
        [card3.topAnchor constraintEqualToAnchor:card2.bottomAnchor constant:14],
    ]];
    // 底部三按钮水平排列（等宽）
    CGFloat bx = 20;
    for (NSUInteger i = 0; i < btns.count; i++) {
        NSButton *btn = btns[i];
        [root addSubview:btn];
        NSLayoutConstraint *bottomPin =
            [btn.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16];
        bottomPin.priority = 999; // 非必需：窗口被拖矮时允许内容溢出，而不是破坏其他约束
        [cons addObjectsFromArray:@[
            [btn.topAnchor constraintEqualToAnchor:card3.bottomAnchor constant:16],
            bottomPin,
            [btn.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:bx],
            [btn.widthAnchor constraintEqualToConstant:188],
        ]];
        bx += 202;
    }
    // 三张卡片撑满宽度
    for (NSView *card in @[card1, card2, card3]) {
        [cons addObjectsFromArray:@[
            [card.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
            [card.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        ]];
    }
    [NSLayoutConstraint activateConstraints:cons];

    // 宽度固定 620（测量时为必需优先级，保证 fittingSize 正确；装进窗口后降为 999 允许拖拽调整）
    NSLayoutConstraint *widthFix = [root.widthAnchor constraintEqualToConstant:620];
    [NSLayoutConstraint activateConstraints:@[widthFix]];
    [root layoutSubtreeIfNeeded];
    CGFloat fitH = [root fittingSize].height;
    if (fitH < 400) fitH = 660; // 兜底，防止异常时窗口过小

    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 620, fitH)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                  | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"右键工具箱";
    w.backgroundColor = [NSColor windowBackgroundColor];
    w.contentView = root;
    widthFix.priority = 999; // 装入窗口后允许用户拖拽调整宽度
    [w center];
    self.window = w;

    [self syncSwitchesFromConfig];
    [self syncTerminalFromConfig];
    [self refreshLog];
    // 仅窗口打开期间 2 秒刷新一次；关窗即退出，无后台开销
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
                                                selector:@selector(softRefresh)
                                                userInfo:nil repeats:YES];
}

#pragma mark - 内部命令通道（URL）

// 扩展跑在沙箱里，不能跨进程发按键（跨进程发键要「辅助功能」授权，而扩展没有 UI、
// 弹不出授权框）。于是给它开一条 URL 命令通道，由本 App（普通 GUI 进程）代劳：
//   rightclicktools://toggle-hidden —— 模拟 ⌘⇧. 切换访达隐藏文件（不重启访达）
// 由 URL 冷启动时不显示管理台，处理完自动退出。
- (void)handleGetURL:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply
{
    NSString *s = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    if (!s.length) return;
    gURLHandled = YES;      // 同步置位：applicationDidFinishLaunching 据此跳过建窗（不闪管理台）
    NSURL *u = [NSURL URLWithString:s];
    dispatch_async(dispatch_get_main_queue(), ^{ [self handleCommandURL:u]; });
}

- (void)handleCommandURL:(NSURL *)url
{
    NSString *cmd = url.host.lowercaseString;
    if ([cmd isEqualToString:@"toggle-hidden"]) {
        if (![self performHiddenToggleViaKeystroke]) [self guideKeystrokePermission];
    }
    [self finishURLCommand];
}

// 处理完退出；但管理台窗口正开着（用户在手动用）就保持不动。
// 弹了系统授权框时延长到 90 秒，否则 App 一退框就没了，用户根本来不及点。
- (void)finishURLCommand
{
    if (self.window) return;
    double delay = gNeedSlowExit ? 90.0 : 2.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    // 被内部命令唤起时不建窗口，处理完自己退出；同时切到「无 Dock 图标」，
    // 免得后台代跑一次按键就在程序坞里闪一下
    if (gURLHandled) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        return;
    }
    [self buildUI];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

#pragma mark - 刷新

- (NSString *)statusText
{
    BOOL extOn  = [FIFinderSyncController isExtensionEnabled];
    BOOL helper = fileExistsExec(HelperUserPath()) || fileExistsExec(HelperContainerPath());
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [NSString stringWithFormat:@"v%@    Finder 扩展：%@    功能脚本：%@",
            ver,
            extOn ? @"✅ 已启用" : @"❌ 未启用",
            helper ? @"✅ 已安装" : @"❌ 未安装"];
}

- (void)syncSwitchesFromConfig
{
    NSMutableDictionary *cfg = [self loadConfig];
    for (NSString *k in self.switches) {
        self.switches[k].state = [(NSNumber *)cfg[k] boolValue]
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)softRefresh
{
    self.statusField.stringValue = [self statusText];
    [self refreshLog];
}

- (void)refreshLog
{
    NSString *log = [NSString stringWithContentsOfFile:LogPath()
                                              encoding:NSUTF8StringEncoding error:nil];
    NSString *text = log.length ? log
        : @"（暂无日志——诊断日志默认关闭；需要调试时打开上方「记录诊断日志」，再右键使用一次功能）";
    if ([self.logView.string isEqualToString:text]) return;
    [self.logView setString:text];
    [self.logView scrollRangeToVisible:NSMakeRange(text.length, 0)];
}

#pragma mark - 动作

- (void)switchChanged:(NSButton *)sender
{
    [self saveConfig];
}

- (void)openExtSettings
{
    [FIFinderSyncController showExtensionManagementInterface];
}

// 在访达里切换隐藏文件：不重启访达，等价于用户亲手按 ⌘⇧.
// 为什么由宿主执行而不是扩展：Finder Sync 扩展跑在独立的沙箱进程里，
// 跨进程发按键要授权，且扩展没有 UI、无法弹授权框。
//
// 实现要点（踩过的两个坑）：
//  ① 不要 shell 出去调 osascript：系统会把责任方认成 osascript 本身，
//     报 “osascript”不允许发送按键 (1002)，用户给「右键工具箱」授权也不生效。
//     改成进程内 CGEventPost，权限就落在本 App 名下，授权一次即可。
//  ② 激活访达用 NSRunningApplication，不需要「自动化」权限——
//     所以本功能只依赖「辅助功能」一项权限。
static BOOL gNeedSlowExit = NO;   // 弹了系统授权框时别 2 秒就退出，否则框会跟着消失

- (BOOL)performHiddenToggleViaKeystroke
{
    // ⌘⇧. 只作用于最前面的窗口，先让访达到最前
    NSRunningApplication *finder =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"].firstObject;
    [finder activateWithOptions:NSApplicationActivateIgnoringOtherApps];

    // 向系统投递按键需要「辅助功能」。没授权时让系统弹标准引导框
    // （会把本 App 自动加进列表，只需打开开关），用户点完再点一次菜单即可。
    if (!AXIsProcessTrusted()) {
        NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
        appendLog(@"[隐藏文件切换] 缺少「辅助功能」权限，已弹出系统引导框");
        gNeedSlowExit = YES;
        return NO;
    }

    // 等访达真正到最前再发键，否则按键会落到别的窗口上
    usleep(300 * 1000);
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)47, true);   // 47 = '.'
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)47, false);
    CGEventFlags f = kCGEventFlagMaskCommand | kCGEventFlagMaskShift;
    CGEventSetFlags(down, f);
    CGEventSetFlags(up, f);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    appendLog(@"[隐藏文件切换] 已向访达投递 ⌘⇧.");
    return YES;
}

// 走到这里说明「辅助功能」已授权但按键仍没生效，给一条能自查的提示
- (void)guideKeystrokePermission
{
    if (gNeedSlowExit) return;      // 系统引导框已经在屏幕上了，不再叠一个
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"切换隐藏文件未生效";
    a.informativeText = @"请确认 系统设置 > 隐私与安全性 > 辅助功能 里\n"
                         "「右键工具箱」的开关是打开的（没有的话点「+」添加 /Applications 里的它）。\n\n"
                         "如果刚改完开关，退出并重新打开一次本 App 再试。";
    [a addButtonWithTitle:@"打开设置"];
    [a addButtonWithTitle:@"知道了"];
    if ([a runModal] == NSAlertFirstButtonReturn)
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)toggleHidden
{
    if ([self performHiddenToggleViaKeystroke]) {
        self.statusField.stringValue = @"已在最前面的访达窗口切换隐藏文件（未重启访达）";
        return;
    }
    [self guideKeystrokePermission];
}

- (void)reinstallHelper
{
    [self installHelper];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = fileExistsExec(HelperUserPath()) ? @"功能脚本已重新安装" : @"安装失败";
    [a runModal];
    self.statusField.stringValue = [self statusText];
}

- (void)openLogFolder
{
    runCmd(@"/usr/bin/open", @[[LogPath() stringByDeletingLastPathComponent]]);
}

- (void)clearLog
{
    [@"" writeToFile:LogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self refreshLog];
}

@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        AppDelegate *del = [AppDelegate new];
        [NSApplication sharedApplication];
        NSApp.delegate = del;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [[NSAppleEventManager sharedAppleEventManager] setEventHandler:del
            andSelector:@selector(handleGetURL:withReplyEvent:)
          forEventClass:kInternetEventClass andEventID:kAEGetURL];
        [del installHelper];
        [NSApp run];
    }
    return 0;
}
