#import "Clock26RootListController.h"
#import <Preferences/PSSpecifier.h>
#import <spawn.h>

static CFStringRef const kClock26PrefsDomain = CFSTR("com.clock26.tweak");
static CFStringRef const kClock26NotifyName = CFSTR("com.clock26.tweak/PrefsChanged");

@implementation Clock26RootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    CFPreferencesSetAppValue((__bridge CFStringRef)specifier.properties[@"key"],
                             (__bridge CFPropertyListRef)value,
                             kClock26PrefsDomain);
    CFPreferencesAppSynchronize(kClock26PrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kClock26NotifyName,
                                         NULL, NULL, YES);
}

- (void)applyScalePreset:(double)scale {
    NSNumber *val = @(scale);
    CFPreferencesSetAppValue(CFSTR("scaleY"), (__bridge CFPropertyListRef)val, kClock26PrefsDomain);
    CFPreferencesAppSynchronize(kClock26PrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kClock26NotifyName,
                                         NULL, NULL, YES);
    [self reloadSpecifiers];
}

- (void)resetToDefault {
    [self applyScalePreset:1.85];
}

- (void)resetToNormal {
    [self applyScalePreset:1.0];
}

- (void)respring {
    pid_t pid;
    const char *sbreloadArgs[] = {"sbreload", NULL};
    if (posix_spawn(&pid, "/var/jb/usr/bin/sbreload", NULL, NULL, (char *const *)sbreloadArgs, NULL) != 0) {
        const char *killallArgs[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)killallArgs, NULL);
    }
}

@end
