//
//     Generated by class-dump 3.5 (64 bit).
//
//     class-dump is Copyright (C) 1997-1998, 2000-2001, 2004-2013 by Steve Nygard.
//

#import <Foundation/Foundation.h>

@class CUIImage;

@protocol CUIThemeImageSource <NSObject>
- (BOOL)hasValueSlices;
- (struct CGSize)imageSize;
- (CUIImage *)imageForState:(long long)arg1 withValue:(long long)arg2;
- (CUIImage *)imageForState:(long long)arg1;
@end

