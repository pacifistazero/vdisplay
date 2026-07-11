#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// These classes are private API living inside CoreGraphics / SkyLight.
// There are no public headers, so we redeclare just enough of the
// interface to drive them. The implementations are resolved from the
// CoreGraphics framework at runtime via the Objective-C runtime.

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
- (instancetype)init;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (dispatch_queue_t)dispatchQueue;
@property(copy, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) struct CGSize sizeInMillimeters;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int serialNum;
@property(copy, nonatomic) void (^terminationHandler)(id _Nullable reason,
                                                      id _Nullable display);
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@property(readonly, nonatomic) unsigned int vendorID;
@property(readonly, nonatomic) unsigned int productID;
@property(readonly, nonatomic) unsigned int serialNum;
@property(readonly, nonatomic) struct CGSize sizeInMillimeters;
@property(readonly, nonatomic) unsigned int maxPixelsWide;
@property(readonly, nonatomic) unsigned int maxPixelsHigh;
@end

NS_ASSUME_NONNULL_END
