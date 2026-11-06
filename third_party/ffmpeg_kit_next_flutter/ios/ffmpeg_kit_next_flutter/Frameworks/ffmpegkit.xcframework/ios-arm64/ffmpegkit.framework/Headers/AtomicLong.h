/*
 * Copyright (c) 2020-2021, 2026 Taner Sener
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

#ifndef FFMPEG_KIT_ATOMIC_LONG_H
#define FFMPEG_KIT_ATOMIC_LONG_H

#import <Foundation/Foundation.h>

/**
 * Represents an atomic long data type.
 */
@interface AtomicLong : NSObject

- (instancetype)initWithValue:(long)value;

- (long)incrementAndGet;

- (long)getAndIncrement;

@end

#endif // FFMPEG_KIT_ATOMIC_LONG_H
