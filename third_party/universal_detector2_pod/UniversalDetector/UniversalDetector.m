//
//  UniversalDetector.m
//  UniversalDetector
//
//  Created by Francis Chong on 7/5/13.
//  Copyright (c) 2013 Ignition Soft. All rights reserved.
//


#import "UniversalDetector.h"
#import "uchardet.h"



@implementation UniversalDetector

- (id)init
{
    self = [super init];
    
    if (self)
    {
        _detector = uchardet_new();
    }
    
    return self;
}


- (void)dealloc
{
    uchardet_delete(_detector);
}


- (CFStringEncoding)encodingWithData:(NSData *)data
{
    NSString *encodingName      = [self encodingAsStringWithData:data];
    if ([encodingName isEqualToString:@""]) {
        return kCFStringEncodingInvalidId;
    }

    CFStringEncoding encoding   = CFStringConvertIANACharSetNameToEncoding((CFStringRef)encodingName);
    return encoding;
}


- (NSString *)encodingAsStringWithData:(NSData *)data
{
    uchardet_handle_data(_detector, [data bytes], [data length]);
    uchardet_data_end(_detector);
    
    const char *charset = uchardet_get_charset(_detector);
    NSString *encoding = [NSString stringWithCString:charset encoding:NSASCIIStringEncoding];
    
    uchardet_reset(_detector);
    
    return encoding;
}


+ (CFStringEncoding)encodingWithData:(NSData *)data
{
    return [[[UniversalDetector alloc] init] encodingWithData:data];
}


+(NSString *)encodingAsStringWithData:(NSData *)data
{
    return [[[UniversalDetector alloc] init] encodingAsStringWithData:data];
}

@end