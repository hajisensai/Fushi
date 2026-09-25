// LNReader 插件在运行时 require 的第三方模块（插件构建产物不内联它们）。
// 版本对齐 LNReader app：cheerio 1.0.0-rc.12 自带 htmlparser2 8。
import * as cheerio from 'cheerio';
import * as htmlparser2 from 'htmlparser2';
import dayjs from 'dayjs';

globalThis.__fushiLnReaderLibs = { cheerio, htmlparser2, dayjs };
