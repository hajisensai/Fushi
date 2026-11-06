/*
 * Copyright (c) 2026 Taner Sener
 *
 * This file is part of FFmpegKitNext.
 *
 * FFmpegKitNext is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * FFmpegKitNext is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General License for more details.
 *
 * You should have received a copy of the GNU Lesser General License
 * along with FFmpegKitNext. If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef FFMPEG_KIT_STREAM_OUTPUT_H
#define FFMPEG_KIT_STREAM_OUTPUT_H

#import <Foundation/Foundation.h>

/**
 * Non-seekable streaming output that can be used in FFmpeg commands with an
 * ffkitstream: URL.
 */
@interface FFmpegKitStreamOutput : NSObject

+ (instancetype)create:(NSString *)extension;

+ (instancetype)create:(NSString *)extension capacity:(long)capacity;

- (NSString *)getUrl;

- (NSData *)read:(int)maxBytes;

- (NSData *)read:(int)maxBytes timeout:(int)timeoutMs;

- (void)close;

@end

#endif // FFMPEG_KIT_STREAM_OUTPUT_H
