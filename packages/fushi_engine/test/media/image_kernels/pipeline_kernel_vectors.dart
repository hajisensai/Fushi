// 封面比对 / 大模型裁图 / TS 字幕解复用 / EPUB 跨页边缘比较 回归向量：pipeline_kernel_cases.dart 每个用例的输出
// 摘要，2026-10-18 由改用原生实现**之前**的纯 Dart 实现生成（以 `/jpeg` 结尾的除外，见行内注释）。
// 原生实现必须逐位复现。不要手改；用例或合成输入改了，就用旧实现重新生成。
const Map<String, String> kPipelineKernelVectors = <String, String>{
  'cover/signature/a':
      '4d914465dd70bc62d513a3f814de2a9d8b9a17c9ba4af3b6d32d3dc0d80335c2',
  'cover/signature/a-rgba':
      'e9f7aa8d84b240dfbc3041ec81d956ceb11b50fbbd9f6ac185389006f918bb03',
  'cover/signature/a-small':
      'c593849415117cb52493fe26c864e211cdfb053282de0c0236a233b903deb72f',
  'cover/signature/a-tiny':
      '71973740dd31fb80478471e1db0d46970fd37ead2d8a450fbe39b35023ae8d58',
  'cover/signature/a-bright':
      '1e3dbf7d5775953989a468cf39408afe96da1a1d9aa45652e129ccce7c09cdf9',
  'cover/signature/a-big':
      '4e3b8703b8e01d700e76725b99dad4ecfce621a7c740df63bf37eb85c95aa608',
  'cover/signature/b':
      'efb995b84bb6ab24cd21a28e7b9fc2ab29b621912f6f93aa9c5fc0fd55796c46',
  'cover/signature/flat':
      'f551883a925f41c1a34f5d3102b0027be3e953797cbf8ce0a2f748dc3a1a8a8a',
  'cover/signature/flat2':
      'be6ecddab63d446215672927909eb7cff49c6680533ad4b28188a2a6fb3309fe',
  'cover/signature/one-pixel':
      '654532334ba3b312c2b8595843a8923202aa16c7abaf8515f018cac8a9c04a62',
  'cover/signature/garbage':
      '8e53a1afaf1a7a48d29c1aaf819a64b5c2bea75ba0609d81900a0a61ad8a59ed',
  'cover/compare/a~a':
      '7989c4e2e326bca62dcd35ccf62b49c67910c9b7e879c39ebf6b41af2e613632',
  'cover/compare/a~a-rgba':
      'b00adfa9d205b1fd63f0eddb49c02b4c2f4a0911db734123b0bddbb71c177579',
  'cover/compare/a~a-small':
      'd27f7a9aec0850db5442d72effeeaf6a6902b854403317f361e114be1f193a87',
  'cover/compare/a~a-tiny':
      '46754e046e54e7cf0e7d000dec573813f6205188f5918d62d66237ae300e6394',
  'cover/compare/a~a-bright':
      '4105f8662bdaa216e01faffe3764c32234c3a4b889dc1ce89d07b302ad7af40b',
  'cover/compare/a~a-big':
      '99be7956e052e9b4d176af23896833041e71fbc7d51c94613df200b40a30b286',
  'cover/compare/a~b':
      '503361d837b93bc708396994e7bfa291be3c219e9012eee967c9fafa2998a8ea',
  'cover/compare/flat~flat':
      '7989c4e2e326bca62dcd35ccf62b49c67910c9b7e879c39ebf6b41af2e613632',
  'cover/compare/flat~flat2':
      '7989c4e2e326bca62dcd35ccf62b49c67910c9b7e879c39ebf6b41af2e613632',
  'cover/compare/flat~a':
      '9d908ecfb6b256def8b49a7c504e6c889c4b0e41fe6ce3e01863dd7b61a20aa0',
  'cover/compare/one-pixel~flat':
      '9d908ecfb6b256def8b49a7c504e6c889c4b0e41fe6ce3e01863dd7b61a20aa0',
  'cover/compare/a~garbage':
      '71cd09eced3c2d35ba506563e000a6f4fe984cdf3e896b4bab10f16c19c14cfe',
  'cover/compare/garbage~a':
      '8e53a1afaf1a7a48d29c1aaf819a64b5c2bea75ba0609d81900a0a61ad8a59ed',
  // 由 Rust 解码生成（JPEG 输入）；与旧 Dart 解码的差异见 PR #2330。
  'cover/compare/a~a-q85/jpeg':
      '5e929afb28b5945cf0be14ead12c1da6633e3269f0c17feb1c47a01c06d1a625',
  'aicrop/rgb/1300.0x1800.0':
      'b4a463553bb40816b0feb841e31e3c52772609976201135fe2cf327df0c41997',
  'aicrop/rgb/650.0x900.0':
      '2bee7309cd687e646f859eced4d005188f3e7b3164ac4b6a017d16191adae70c',
  'aicrop/rgb/0.0x0.0':
      'b4a463553bb40816b0feb841e31e3c52772609976201135fe2cf327df0c41997',
  'aicrop/rgb/1000.0x1500.0':
      'f170f3b2b639fcaa765579e4046b036109cd321b9032bd1f18ab860bcfca2c84',
  'aicrop/rgba/1300.0x1800.0':
      'c0897bdab0aa5de882ae310bfb13b56edf6a8be2ae52bcf6d3523a839ddfd9af',
  'aicrop/rgba/650.0x900.0':
      '261feb9dc3cd51d37f60e4b8b63cb2ef9454675e9c18e887942f18b9e5926618',
  'aicrop/rgba/0.0x0.0':
      '0acc2b86db2844c2fa60833e09b1104bb3549de998a806ef7be43a4960fbdeb9',
  'aicrop/rgba/1000.0x1500.0':
      '66db30d8227e2a881cc0c31391e8d1a8084ef88c88cdfe9d2616c17b864138db',
  'aicrop/small/1300.0x1800.0':
      '068e76f76839dd0a65e12a963e1ce2b21eeff80610ea928415fd70e4a0842447',
  'aicrop/small/650.0x900.0':
      '6c6e23f77f0c550fe18784643c854373d15a067ca0c71168c5d872107d93825f',
  'aicrop/small/0.0x0.0':
      '9acb2b960c41ec590da3844e112d8dcaf5468ce92cae643316b870f2abcf4a71',
  'aicrop/small/1000.0x1500.0':
      '36057a71d35af905b6c8f4486636773e41e086555f15b3257351dfc46ced5ce7',
  'aicrop/garbage': 'nnnnnnnn',
  'aicrop/nan-box': 'UnsupportedError',
  'ts/1/1.0/complete':
      'd8f8862f0e35f579181897421dfa6c0b2f417308dc32a19ba6b80532c9949a9d',
  'ts/1/1.0/growing':
      'd8f8862f0e35f579181897421dfa6c0b2f417308dc32a19ba6b80532c9949a9d',
  'ts/1/0.73/complete':
      '1a62136f0fcb7343ec51a6d8e68c044f00944221e2c164391d1afa50d84856b5',
  'ts/1/0.73/growing':
      '1a62136f0fcb7343ec51a6d8e68c044f00944221e2c164391d1afa50d84856b5',
  'ts/1/0.5/complete':
      'd3709859dd3e05b159cc11234edba266bb0ed9f3818b2f10cc65633c1aa4c915',
  'ts/1/0.5/growing':
      'd3709859dd3e05b159cc11234edba266bb0ed9f3818b2f10cc65633c1aa4c915',
  'ts/1/0.21/complete':
      '18cd179971296d7df455aeb0f168ddaee46a5277b23f71f2cb3692a59ceaa8ba',
  'ts/1/0.21/growing':
      '18cd179971296d7df455aeb0f168ddaee46a5277b23f71f2cb3692a59ceaa8ba',
  'ts/2/1.0/complete':
      '7bad679b5ddf61885371211728053c74fcb858355653742b20e115f15031e162',
  'ts/2/1.0/growing':
      '7bad679b5ddf61885371211728053c74fcb858355653742b20e115f15031e162',
  'ts/2/0.73/complete':
      '0716ce4575e792dd94b2e7d146186126fdebdd72d4fd390105da9c8972630ed7',
  'ts/2/0.73/growing':
      '0716ce4575e792dd94b2e7d146186126fdebdd72d4fd390105da9c8972630ed7',
  'ts/2/0.5/complete':
      'ed21ce136ea311a26c5d029446bb4cdcccd98441a218a93f372810693647d552',
  'ts/2/0.5/growing':
      'ed21ce136ea311a26c5d029446bb4cdcccd98441a218a93f372810693647d552',
  'ts/2/0.21/complete':
      '12c125d95cf135b790f795721a563dedb478e5afcc230225482393d36740fec3',
  'ts/2/0.21/growing':
      '12c125d95cf135b790f795721a563dedb478e5afcc230225482393d36740fec3',
  'ts/3/1.0/complete':
      '70343be36b9f368a8612c27103ea5d6c8f7b0c6684b1c297d0cb35e513775e1d',
  'ts/3/1.0/growing':
      '70343be36b9f368a8612c27103ea5d6c8f7b0c6684b1c297d0cb35e513775e1d',
  'ts/3/0.73/complete':
      '3a13eed00165bdbb030f1d83b8801ad74e39ec9655030352c4b5bdfdcb2264f9',
  'ts/3/0.73/growing':
      '3a13eed00165bdbb030f1d83b8801ad74e39ec9655030352c4b5bdfdcb2264f9',
  'ts/3/0.5/complete':
      'b9c0c4573477907a880e768915efbfe315d00b30aa3cff7dfd614cf62eb99d32',
  'ts/3/0.5/growing':
      'b9c0c4573477907a880e768915efbfe315d00b30aa3cff7dfd614cf62eb99d32',
  'ts/3/0.21/complete':
      '027a1991f28106ea559f4d18ced9ae3d1c9a2f3f9e23bc1ba8230c2deff0072d',
  'ts/3/0.21/growing':
      '027a1991f28106ea559f4d18ced9ae3d1c9a2f3f9e23bc1ba8230c2deff0072d',
  'ts/4/sweep':
      '6c005b49898c63f8572ae4a8db49ef0d4bcc172cb8a4994993e63f8a04dd57f1',
  'ts/5/sweep':
      'd0b32a76d379766df1eeb664b0db9ee5b785334542f5024602999e6ed75ea1ad',
  'ts/empty':
      '9d908ecfb6b256def8b49a7c504e6c889c4b0e41fe6ce3e01863dd7b61a20aa0',
  // EPUB 跨页边缘比较：分数（double.toString，可逆），由搬进原生之前的
  // EpubEdgeMatcher.compareEdges（package:image 解码 + copyResize + getPixel）生成。
  // 1 通道灰度 PNG 是有意的行为变化：package:image 把它解成 1 通道，旧比较按 PixelUint8 读成
  // (l, 0, 0)，只有 R 差、再被除以 3；原生解码把灰度展开成 (l, l, l)。下面两条等于旧实现对
  // 同一张图先 convert 成 3 通道再比的结果（旧值 0.9211260893246188 / 0.8836737472766887）。
  'epub/edge/spread/1ch': '0.7633782679738561',
  'epub/edge/unrelated/1ch': '0.6510212418300649',
  'epub/edge/spread/2ch': '0.7682802287581698',
  'epub/edge/unrelated/2ch': '0.628880718954248',
  'epub/edge/spread/3ch': '0.7401552287581699',
  'epub/edge/unrelated/3ch': '0.6027301198257078',
  'epub/edge/spread/4ch': '0.7425789760348582',
  'epub/edge/unrelated/4ch': '0.6534381808278866',
  'epub/edge/spread/3ch/strip1/h64': '0.9086601307189544',
  'epub/edge/spread/3ch/strip8/h64': '0.6616421568627446',
  'epub/edge/spread/3ch/strip3/h16': '0.6061002178649237',
  'epub/edge/spread/3ch/strip3/h200': '0.9035294117647054',
  'epub/edge/spread/3ch/strip3/h1': '0.0',
  'epub/edge/mixed-size': '0.6652028867102395',
  'epub/edge/upscale': '0.6901960784313728',
  'epub/edge/narrow': '0.0',
  'epub/edge/palette': '0.6616557734204793',
  'epub/edge/garbage-left': '0.0',
  'epub/edge/garbage-right': '0.0',
};
