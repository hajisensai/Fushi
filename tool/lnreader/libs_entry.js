// LNReader 插件在运行时 require 的第三方模块（插件构建产物不内联它们）。
// 版本对齐 LNReader app：cheerio 1.0.0-rc.12 自带 htmlparser2 8。
import * as cheerio from 'cheerio';
import * as htmlparser2 from 'htmlparser2';
import dayjs from 'dayjs';
import customParseFormat from 'dayjs/plugin/customParseFormat';
import localeData from 'dayjs/plugin/localeData';
import localizedFormat from 'dayjs/plugin/localizedFormat';
import relativeTime from 'dayjs/plugin/relativeTime';
import calendar from 'dayjs/plugin/calendar';
import duration from 'dayjs/plugin/duration';
// LNReader app 包表里的 `@libs/fetch.fetchProto`（gRPC-web，wuxiaworld）与
// `@libs/aes` / `@libs/utils`（AES-GCM 解密章节，wtrlab）用的同一批库、同一版本。
import { parse as parseProto } from 'protobufjs';
import { gcm } from '@noble/ciphers/aes.js';
import { utf8ToBytes, bytesToUtf8 } from '@noble/ciphers/utils.js';

// LNReader app 启动时对全局 dayjs 装的同一组扩展（src/i18n/translations.ts）；
// 插件 require('dayjs') 拿到的就是这个实例。缺了它们 madara 系插件的
// `dayjs(...).format('LL')` 原样返回字面量 "LL"，章节日期显示成 "LL"。
dayjs.extend(customParseFormat);
dayjs.extend(localeData);
dayjs.extend(localizedFormat);
dayjs.extend(relativeTime);
dayjs.extend(calendar);
dayjs.extend(duration);

globalThis.__fushiLnReaderLibs = {
  cheerio,
  htmlparser2,
  dayjs,
  parseProto,
  gcm,
  utf8ToBytes,
  bytesToUtf8,
};
