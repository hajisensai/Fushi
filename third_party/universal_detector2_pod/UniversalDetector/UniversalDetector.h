//
//  UniversalDetector.h
//  UniversalDetector
//
//  Created by Francis Chong on 7/5/13.
//  Copyright (c) 2013 Ignition Soft. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "uchardet.h"

@interface UniversalDetector : NSObject {
@private
    uchardet_t _detector;
}

/**
 Detect encoding of given NSData.
 @return encoding of the given NSData, or kCFStringEncodingInvalidId if the encoding cannot be determined OR is ASCII.
 */
- (CFStringEncoding)encodingWithData:(NSData *)data;

/**
 Detect encoding of given NSData.
 @return encoding of the given NSData as string, or empty string if the encoding cannot be determined OR is ASCII.
 */
- (NSString *)encodingAsStringWithData:(NSData *)data;

/**
 Create a instance of detector and detect encoding of given NSData.
 @return encoding of the given NSData, or kCFStringEncodingInvalidId if the encoding cannot be determined OR is ASCII.
 */
+ (CFStringEncoding)encodingWithData:(NSData *)data;

/**
 Detect encoding of given NSData.
 @return encoding of the given NSData as string, or empty string if the encoding cannot be determined OR is ASCII.
 */
+ (NSString *)encodingAsStringWithData:(NSData *)data;

@end