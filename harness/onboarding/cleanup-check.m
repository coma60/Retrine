#import "App/Onboarding/Onboarding.h"
#import "Settings/SGModPage.h"
#import "../harness-fail.h"

@interface CleanupPage : SGModPage
@property NSString *expectedSubtitle;
@property SGModRow *cleanup;
@property NSUInteger alerts;
@end
@implementation CleanupPage
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(dispatch_block_t)completion {
    HARNESS_CHECK([controller isKindOfClass:UIAlertController.class]);
    HARNESS_CHECK(controller.overrideUserInterfaceStyle == UIUserInterfaceStyleDark);
    self.alerts++;
    if (self.alerts == 2) {
        HARNESS_CHECK([[(UIAlertController *)controller actions].lastObject.title isEqual:@"Keep"]);
        puts("PASS kept cleanup size, delete action and dark environment alerts");
        exit(0);
    }
}
- (void)tableView:(UITableView *)table willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)path {
    UIListContentConfiguration *content = (id)cell.contentConfiguration;
    if (![content.text isEqual:self.cleanup.title]) return;
    HARNESS_CHECK([content.secondaryText isEqual:self.expectedSubtitle]);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.sections.firstObject.rows.firstObject.action(); // The harness version triggers the install warning.
        self.cleanup.action();
    });
}
@end

void CheckKeptCleanup(UIWindow *window) {
    // The persisted result of Keep, in a fresh process that has never shown the offer.
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"spotifyglass.environment.chromaCleanupOffered"];
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [support URLByAppendingPathComponent:@"spoti.pw/Sing"];
    HARNESS_CHECK([files createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *file = [dir URLByAppendingPathComponent:@"fixture"];
    HARNESS_CHECK([[NSMutableData dataWithLength:65536] writeToURL:file atomically:YES]);
    NSNumber *bytes;
    HARNESS_CHECK([file getResourceValue:&bytes forKey:NSURLTotalFileAllocatedSizeKey error:nil]);
    NSArray *rows = SGEnvironmentWarningRows();
    HARNESS_CHECK(rows.count >= 2);
    CleanupPage *page = [[CleanupPage alloc] initWithTitle:@"Settings" intro:nil sections:@[SGSection(nil, rows)] footer:nil];
    page.cleanup = rows.lastObject;
    HARNESS_CHECK([page.cleanup.title isEqual:@"Chroma left files behind"]);
    page.expectedSubtitle = [NSString stringWithFormat:@"%@ Retrine never uses. Tap to delete",
        [NSByteCountFormatter stringFromByteCount:bytes.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    window.rootViewController = page;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        HARNESS_FAIL(@"cleanup row did not refresh or present its alerts");
    });
}
