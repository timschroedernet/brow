//
//  TSMonitorController.m
//  Brow
//
//  Created by Tim Schröder on 27.06.16.
//  Copyright © 2016 Tim Schröder. All rights reserved.
//

#import "TSMonitorController.h"
#import "TSChromeConnector.h"
#import "TSFirefoxConnector.h"
#import "TSSyncController.h"
#import "TSStream.h"
#import <CoreServices/CoreServices.h>
#import "TSLogger.h"

@implementation TSMonitorController

NSMutableArray *chromeStreams;
NSDate *chromeLastChangeDate;
NSDate *firefoxLastChangeDate;

static TSMonitorController *_sharedController = nil;

#pragma mark -
#pragma mark Singleton Methods

+ (TSMonitorController *)sharedController
{
    if (!_sharedController) {
        _sharedController = [[super allocWithZone:NULL] init];
    }
    return _sharedController;
}

+ (id)allocWithZone:(NSZone *)zone
{
    return [self sharedController];
}

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}


#pragma mark -
#pragma mark Overriden Methods

-(id)init
{
    if (self = [super init]) {
        chromeMonitoringIsActive = NO;
        firefoxMonitoringIsActive = NO;
        chromeLastChangeDate = nil;
        firefoxLastChangeDate = nil;
    }
    return (self);
}

#pragma mark -
#pragma mark Monitoring Callback Handling

//
// Internal Helper Methods

//-(BOOL)prefPaneMissing // checks if prefPane has been deinstalled, if yes, remove brow-helper
// See Where Preference Panes Live
// in https://developer.apple.com/library/mac/documentation/UserExperience/Conceptual/PreferencePanes/Concepts/Anatomy.html#//apple_ref/doc/uid/20000705-CJBCABAB
// /Network/Library/PreferencePanes
// /Library/PreferencePanes
// ~/Library/PreferencePanes
// AND also remove brow-importer 

// Terminate brow-helper
-(void)terminateHelper
{
    //[NSApp terminate:<#(nullable id)#>]
}


void fsevents_callback(ConstFSEventStreamRef streamRef,
                       void *userData,
                       size_t numEvents,
                       void *eventPaths,
                       const FSEventStreamEventFlags eventFlags[],
                       const FSEventStreamEventId eventIds[])
// TODO nur selektiv synchronisieren, wenn mehrere Profile beobachtet werden!
{
    int i;
    NSArray *paths = (__bridge NSArray*)eventPaths;
    
    for (i=0; i<numEvents; i++) {
        NSString *path = [paths objectAtIndex:i];
        TSLog (@"fsevents_callback for %@", path);
        
        // Auf Chrome testen
        NSArray *chromeDirs = [[TSChromeConnector sharedConnector] bookmarkFileDirectories];
        BOOL foundChromeDir = NO;
        for (id chromeDir in chromeDirs)
        {
            NSString *dir = [chromeDir stringByAppendingString:@"/"];
            if ([path isEqualToString:dir])
            {
                foundChromeDir = YES;
            }
        }
        if (foundChromeDir) {
            TSLog (@"fsevents_callback for Chrome: %@", path);
            path = [path stringByAppendingPathComponent:[[TSChromeConnector sharedConnector] bookmarkFile]];
            NSDate *modDate = [[[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                                                error:nil] fileModificationDate];
            if (chromeLastChangeDate) {
                if (![modDate isEqualToDate:chromeLastChangeDate]) {
                    // Re-Index Bookmarks
                    [[TSSyncController sharedController] syncChromeBookmarks];
                    
                    chromeLastChangeDate = modDate;
                    TSLog (@"chrome bookmarks changed");
                }
            } else {
                // Re-Index Bookmarks
                [[TSSyncController sharedController] syncChromeBookmarks];
                
                chromeLastChangeDate = modDate;
                TSLog (@"chrome bookmarks changed");
            }
        }
        
        // Auf Firefox testen
        NSString *firefoxDir = [[TSFirefoxConnector sharedConnector] fullBookmarkPathWithFileName:NO];
        firefoxDir = [firefoxDir stringByAppendingString:@"/"];
        if ([path isEqualToString:firefoxDir]) {
            TSLog (@"fsevents_callback for Firefox: %@", path);
            NSArray *firefoxChangePaths = [[TSFirefoxConnector sharedConnector] bookmarkFiles];
            for (NSString *findPath in firefoxChangePaths)
            {
                NSString *checkPath = [path stringByAppendingPathComponent:findPath];
                NSDate *modDate = [[[NSFileManager defaultManager] attributesOfItemAtPath:checkPath
                                                                                    error:nil] fileModificationDate];
                if (firefoxLastChangeDate) {
                    if (![modDate isEqualToDate:firefoxLastChangeDate]) {
                        // Re-Index Bookmarks
                        TSLog (@"Firefox bookmarks changed, re-synchronizing ..");
                        [[TSSyncController sharedController] syncFirefoxBookmarks];
                        firefoxLastChangeDate = modDate;
                    }
                } else {
                    // Index Bookmarks for the first time
                    TSLog (@"Firefox bookmarks changed, synchronizing for the first time ..");
                    
                    [[TSSyncController sharedController] syncFirefoxBookmarks];
                    firefoxLastChangeDate = modDate;
                }
            }
        }
    }
    
}


#pragma mark -
#pragma mark Monitor Administration Methods

-(FSEventStreamRef)startMonitoringForStream:(FSEventStreamRef)stream withPath:(NSString*)path
{
    TSLog (@"startMonitoringForStream: %@", path);
    NSArray *pathsToWatch = [NSArray arrayWithObject:path];
    void *appPointer = (__bridge void*)self;
    FSEventStreamContext context = {0, appPointer, NULL, NULL, NULL};
    NSTimeInterval latency = 3.0;
    stream = FSEventStreamCreate(NULL,
                                 &fsevents_callback,
                                 &context,
                                 (__bridge CFArrayRef) pathsToWatch,
                                 kFSEventStreamEventIdSinceNow,
                                 (CFAbsoluteTime) latency,
                                 kFSEventStreamCreateFlagUseCFTypes
                                 );
    FSEventStreamScheduleWithRunLoop(stream,
                                     CFRunLoopGetCurrent(),
                                     kCFRunLoopDefaultMode);
    FSEventStreamStart (stream);
    return stream;
}

-(void)stopMonitoringForStream:(FSEventStreamRef)stream
{
    if (stream != NULL) {
        FSEventStreamStop (stream);
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease (stream);
    }
}


#pragma mark -
#pragma mark Public Methods

-(void)startChromeMonitoring
// TODO: Wenn neues Profil angelegt wird, während Monitoring läuft, muss neues Profil mit aufgenommen werden
// TODO: Wenn bestehendes Profil gelöscht wird, während Monitoring läuft, muss Profil entfernt werden
// TODO: Wahrscheinlich Extra-Monitoring
{
    TSLog (@"startChromeMonitoring");
    
    // Synchronize on start
    [[TSSyncController sharedController] syncChromeBookmarks];
    
    // Return if we're already running
    if (chromeMonitoringIsActive) return;
    
    // Start Monitoring
    if (chromeStreams) {
        [chromeStreams removeAllObjects];
    } else {
        chromeStreams = [NSMutableArray arrayWithCapacity:0];
    }
    NSArray *bookmarkFilePaths = [[TSChromeConnector sharedConnector] bookmarkFileDirectories];
    for (id path in bookmarkFilePaths)
    {
        FSEventStreamRef chromeStream;
        chromeStream = [self startMonitoringForStream:chromeStream withPath:path];
        TSStream *streamObject = [[TSStream alloc] init];
        [streamObject setStream:chromeStream];
        [chromeStreams addObject:streamObject];
    }
    chromeMonitoringIsActive = YES;
}

-(void)stopChromeMonitoring
{
    TSLog (@"stopChromeMonitoring");
    if (!chromeMonitoringIsActive) return;
    for (id stream in chromeStreams)
    {
        [self stopMonitoringForStream:[stream getStream]];
    }
    chromeMonitoringIsActive = NO;
}

-(void)startFirefoxMonitoring
// TODO Multi-Profile erfassen wie Chrome
{
    TSLog (@"startFirefoxMonitoring");
    
    // Synchronize on start
    [[TSSyncController sharedController] syncFirefoxBookmarks];
    
    // Return if we're already running
    if (firefoxMonitoringIsActive) return;
    
    // Retrieve path of bookmark file
    NSString *fullPath;
    fullPath = [[TSFirefoxConnector sharedConnector] fullBookmarkPathWithFileName:NO];
    
    // Start Monitoring
    firefoxStream = [self startMonitoringForStream:firefoxStream withPath:fullPath];
    firefoxMonitoringIsActive = YES;
}

-(void)stopFirefoxMonitoring
{
    TSLog (@"stopFirefoxMonitoring");
    if (!firefoxMonitoringIsActive) return;
    [self stopMonitoringForStream:firefoxStream];
    firefoxMonitoringIsActive = NO;
}


@end
