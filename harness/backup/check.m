#import <UIKit/UIKit.h>
#import <sys/stat.h>
static NSString *exportDirectory;
#define NSTemporaryDirectory() exportDirectory
#import "App/About/Backup.m"
#undef NSTemporaryDirectory
#import "../harness-fail.h"

@interface ExportPresenter : UIViewController
@property UIViewController *last;
@end
@implementation ExportPresenter
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    self.last = controller;
}
@end
static ExportPresenter *owner;
UIViewController *SGTopController(void) { return owner; }

static void runChecks(void) {
    @autoreleasepool {
        NSString *suite = [@"retrine.backup.check." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *store = [[NSUserDefaults alloc] initWithSuiteName:suite];
        NSString *wg = @"spotifyglass.wireguard", *server = SGKeySponsorBlockServer;
        NSString *ordinary = SGKeySponsorBlock;
        NSDictionary *local = @{wg: @{@"host": @"local.example"}, server: @"https://local.example", ordinary: @NO};
        [store setPersistentDomain:local forName:suite];
        NSDictionary *exported = exportSettings(local);
        importSettings(@{wg: @{@"host": @"import.example"}, server: @"https://import.example", ordinary: @YES}, store, local);
        NSDictionary *after = [store persistentDomainForName:suite];
        [store removePersistentDomainForName:suite];
        BOOL exportOK = [exported isEqual:@{ordinary: @NO}];
        BOOL importOK = [after isEqual:@{wg: local[wg], server: local[server], ordinary: @YES}];
        if (!exportOK || !importOK) HARNESS_FAIL(@"private settings: export %d, import %d", exportOK, importOK);
        owner = [ExportPresenter new];
        exportDirectory = NSProcessInfo.processInfo.environment[@"EXPORT_DIR"];
        NSString *path = [exportDirectory stringByAppendingPathComponent:@"spotifyglass-settings.json"];
        HARNESS_CHECK([@"stale" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        HARNESS_CHECK(chmod(exportDirectory.fileSystemRepresentation, 0500) == 0);
        SGExportSettings();
        HARNESS_CHECK(chmod(exportDirectory.fileSystemRepresentation, 0700) == 0);
        HARNESS_CHECK([owner.last isKindOfClass:UIAlertController.class]);
        HARNESS_CHECK(owner.last.overrideUserInterfaceStyle == UIUserInterfaceStyleDark);
        HARNESS_CHECK([[(UIAlertController *)owner.last message] length] > 0);
        HARNESS_CHECK([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqual:@"stale"]);
        puts("backup: ok");
    }
    exit(0);
}

@interface BackupApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation BackupApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [UIWindow new];
    self.window.rootViewController = [UIViewController new];
    dispatch_async(dispatch_get_main_queue(), ^{ runChecks(); });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(BackupApp.class)); }
}
