/*
 * Copyright (c) 2019-2021, 2026 Taner Sener
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

class ReturnCode {
  static const int success = 0;
  static const int cancel = 255;

  int _value;

  ReturnCode(this._value);

  static bool isSuccess(ReturnCode? returnCode) =>
      returnCode?.getValue() == ReturnCode.success;

  static bool isCancel(ReturnCode? returnCode) =>
      returnCode?.getValue() == ReturnCode.cancel;

  int getValue() => this._value;

  bool isValueSuccess() => this._value == ReturnCode.success;

  bool isValueError() =>
      (this._value != ReturnCode.success) && (this._value != ReturnCode.cancel);

  bool isValueCancel() => this._value == ReturnCode.cancel;

  String toString() => this._value.toString();
}
