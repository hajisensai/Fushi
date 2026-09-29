/// Pinned Windows x64 MangaOCR CUDA assets, verified 2026-09-23.
///
/// CPython's embeddable ZIP plus a complete binary-wheel dependency closure.
/// Install only from these SHA256-verified files with --no-index,
/// --only-binary=:all: and --require-hashes. No system Python or CUDA toolkit
/// is required; the NVIDIA driver remains a host prerequisite.
library;

import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';

const String kMangaOcrCudaRuntimeVersion = 'python3119-torch280-cu128-v1';
const String kMangaOcrCudaPythonArchiveFileName =
    'python-3.11.9-embed-amd64.zip';
const String kMangaOcrCudaPipWheelFileName = 'pip-25.3-py3-none-any.whl';
const String kMangaOcrCudaModelRevision =
    'aa6573bd10b0d446cbf622e29c3e084914df9741';

/// Written as python311._pth next to the embedded python.exe. Registry,
/// PYTHONPATH and user site-packages remain disabled by isolated mode.
const String kMangaOcrCudaPythonPathConfiguration =
    'python311.zip\n.\nLib/site-packages\nimport site\n';

/// Python plus all declared transitive dependencies for Windows CPython 3.11.
/// The pip wheel is also the bootstrap: extract it into Lib/site-packages.
/// VC++ CRT DLLs must be supplied app-locally from the existing Windows app
/// bundle; neither the Python ZIP nor torch contains msvcp140.dll.
const List<MangaOcrModelFile> kMangaOcrCudaRuntimeManifest =
    <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'python-3.11.9-embed-amd64.zip',
    url:
        'https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip',
    expectedBytes: 11249023,
    sha256: '009d6bf7e3b2ddca3d784fa09f90fe54336d5b60f0e0f305c37f400bf83cfd3b',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'annotated_doc-0.0.5-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/3e/30/e900b21425a860e195f32e37657aa1f7c7f2b1bfb26f03ca209b90933c06/annotated_doc-0.0.5-py3-none-any.whl',
    expectedBytes: 5302,
    sha256: '117bac03a25ede5df5440e855b32d556049ca169ead221505badf432fed4b101',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'anyio-4.15.1-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/12/b8/4bd346e22b28902df4d651910f5242c28d84e4a5c2435ca5c3f797ed7e2e/anyio-4.15.1-py3-none-any.whl',
    expectedBytes: 132079,
    sha256: '6152fdbbf9a77fdec97731721bebf7c4c44f7c29b424b0065826173efc7ed101',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'certifi-2026.7.22-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/0b/a7/71ac2cff56fec219ed242bb11b8efb69fcc4bec75db06fb7bfe35de520e6/certifi-2026.7.22-py3-none-any.whl',
    expectedBytes: 136983,
    sha256: '62f22742b58a1a33014a2b6b706588a8d7e2a88ae7bd1a6ebe8c992928483775',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'click-8.5.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/58/50/6c0d534c5f134586a8e1ba4e330569e32f057e33372ae556463212fb4cd3/click-8.5.0-py3-none-any.whl',
    expectedBytes: 125251,
    sha256: '255bc9599cf7748b4b1a446ccc735421bd08a2ae529a8b88597d3de5664ee360',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'colorama-0.4.6-py2.py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/d1/d6/3965ed04c63042e047cb6a3e6ed1a63a35087b6a609aa3a15ed8ac56c221/colorama-0.4.6-py2.py3-none-any.whl',
    expectedBytes: 25335,
    sha256: '4f1d9991f5acc0ca119f9d443620b77f9d6b33703e51011c16baf57afb285fc6',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'filelock-4.0.1-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/29/33/af0635ab07fe83b1788a1dbe370ff3e226062495a998335cb18a1cac81aa/filelock-4.0.1-py3-none-any.whl',
    expectedBytes: 106219,
    sha256: '481a321a27bef441e23c53371c6abc8d7d16e26b97090074ba44f7538a3fd55a',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'fsspec-2026.9.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/6c/c0/a98505f18594f1bce828bb159cec0fcf9860562f1a2c85913409fc8f3d9e/fsspec-2026.9.0-py3-none-any.whl',
    expectedBytes: 221738,
    sha256: '8dd6e646e99ea382bd85f97a45e6b526a442d79423a7dc673f1e2756d05fcb5f',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'h11-0.16.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/04/4b/29cac41a4d98d144bf5f6d33995617b185d14b22401f75ca86f384e87ff1/h11-0.16.0-py3-none-any.whl',
    expectedBytes: 37515,
    sha256: '63cf8bbe7522de3bf65932fda1d9c2772064ffb3dae62d55932da54b31cb6c86',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'hf_xet-1.6.0-cp38-abi3-win_amd64.whl',
    url:
        'https://files.pythonhosted.org/packages/98/b7/8c59a66d15205024662f1d66968136f13893f96df1ddc5087e2e281fc95f/hf_xet-1.6.0-cp38-abi3-win_amd64.whl',
    expectedBytes: 4033128,
    sha256: 'fb4fadde1b2b70bf4c0c14a6dccbe7194b1c28947fefd5bbe3fed9d940676c3b',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'httpcore-1.0.9-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/7e/f5/f66802a942d491edb555dd61e3a9961140fd64c90bce1eafd741609d334d/httpcore-1.0.9-py3-none-any.whl',
    expectedBytes: 78784,
    sha256: '2d400746a40668fc9dec9810239072b40b4484b640a8c38fd654a024c7a1bf55',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'httpx-0.28.1-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/2a/39/e50c7c3a983047577ee07d2a9e53faf5a69493943ec3f6a384bdc792deb2/httpx-0.28.1-py3-none-any.whl',
    expectedBytes: 73517,
    sha256: 'd909fcccc110f8c7faf814ca82a9a4d816bc5a6dbfea25d6591d6985b8ba59ad',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'huggingface_hub-1.32.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/1b/cf/d98dd561d6d0d7b7d7a64d1563f8aaaa7c235daee41c1c9bcc3da62420ed/huggingface_hub-1.32.0-py3-none-any.whl',
    expectedBytes: 842906,
    sha256: 'b0c7c80561969d9cdacdd55fce67ba9584cca0b9d4ea80957a3a5c1445fac5c8',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'idna-3.20-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/58/a2/bb081bab032533a855d44de1d56f8e8426114ff1ba5d1f07a438a0a654f8/idna-3.20-py3-none-any.whl',
    expectedBytes: 69583,
    sha256: 'ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'jaconv-0.5.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/3b/da/9657d637bcacdbaf6a914ce504000da5639f9d945f8d3552a940f021d6c0/jaconv-0.5.0-py3-none-any.whl',
    expectedBytes: 16831,
    sha256: '2914114fe761ca49fc7089e25e6ad4a400c26f262ffce84e13b176916b71610a',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'jinja2-3.1.6-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/62/a1/3d680cbfd5f4b8f15abc1d571870c5fc3e594bb582bc3b64ea099db13e56/jinja2-3.1.6-py3-none-any.whl',
    expectedBytes: 134899,
    sha256: '85ece4451f492d0c13c5dd7c13a64681a86afae63a5f347908daf103ce6d2f67',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'markdown_it_py-4.2.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/b3/81/4da04ced5a082363ecfa159c010d200ecbd959ae410c10c0264a38cac0f5/markdown_it_py-4.2.0-py3-none-any.whl',
    expectedBytes: 91687,
    sha256: '9f7ebbcd14fe59494226453aed97c1070d83f8d24b6fc3a3bcf9a38092641c4a',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'markupsafe-3.0.3-cp311-cp311-win_amd64.whl',
    url:
        'https://files.pythonhosted.org/packages/83/8a/4414c03d3f891739326e1783338e48fb49781cc915b2e0ee052aa490d586/markupsafe-3.0.3-cp311-cp311-win_amd64.whl',
    expectedBytes: 15077,
    sha256: 'de8a88e63464af587c950061a5e6a67d3632e36df62b986892331d4620a35c01',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'mdurl-0.1.2-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/b3/38/89ba8ad64ae25be8de66a6d463314cf1eb366222074cfda9ee839c56a4b4/mdurl-0.1.2-py3-none-any.whl',
    expectedBytes: 9979,
    sha256: '84008a41e51615a49fc9966191ff91509e3c40b939176e643fd50a5c2196b8f8',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'mpmath-1.3.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/43/e3/7d92a15f894aa0c9c4b49b8ee9ac9850d6e63b03c9c32c0367a13ae62209/mpmath-1.3.0-py3-none-any.whl',
    expectedBytes: 536198,
    sha256: 'a0b2b9fe80bbcd81a6647ff13108738cfb482d481d826cc0e02f5b35e5c88d2c',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'networkx-3.6.1-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/9e/c9/b2622292ea83fbb4ec318f5b9ab867d0a28ab43c5717bb85b0a5f6b3b0a4/networkx-3.6.1-py3-none-any.whl',
    expectedBytes: 2068504,
    sha256: 'd47fbf302e7d9cbbb9e2555a0d267983d2aa476bac30e90dfbe5669bd57f3762',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'numpy-2.4.6-cp311-cp311-win_amd64.whl',
    url:
        'https://files.pythonhosted.org/packages/c5/31/7fc6239c12bce7e931463251cca4426c465e1876ba3cc785402ef4dd8f4e/numpy-2.4.6-cp311-cp311-win_amd64.whl',
    expectedBytes: 12608406,
    sha256: '1e254a00cdf42b1e4d5b3d68d33af63268d41340d8885df2ab6470f2e1500147',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'packaging-26.3-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/63/34/ba1c580383c9eada3711951fef0795c80b829a078d72188184bcab9dd527/packaging-26.3-py3-none-any.whl',
    expectedBytes: 129956,
    sha256: 'd7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'pillow-12.3.0-cp311-cp311-win_amd64.whl',
    url:
        'https://files.pythonhosted.org/packages/63/c6/4bad1b18d132a50b27e1365e1ab163616f7a5bb56d330f66f9d1d9d4f9d4/pillow-12.3.0-cp311-cp311-win_amd64.whl',
    expectedBytes: 7233653,
    sha256: '8e95e1385e4998ae9694eeaa4730ba5457ff61185b3a55e2e7bea0880aef452a',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'pip-25.3-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/44/3c/d717024885424591d5376220b5e836c2d5293ce2011523c9de23ff7bf068/pip-25.3-py3-none-any.whl',
    expectedBytes: 1778622,
    sha256: '9655943313a94722b7774661c21049070f6bbb0a1516bf02f7c8d5d9201514cd',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'pygments-2.21.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/71/46/17f022dd3e953bf20a04a028a21ec746d942f8d2af30fa0f124fa0e6a684/pygments-2.21.0-py3-none-any.whl',
    expectedBytes: 1250147,
    sha256: '2363c69b61c4a97c838da3b130dcd6468f4848992b21a82f2a63ec34377137d9',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'pyyaml-6.0.3-cp311-cp311-win_amd64.whl',
    url:
        'https://files.pythonhosted.org/packages/da/e3/ea007450a105ae919a72393cb06f122f288ef60bba2dc64b26e2646fa315/pyyaml-6.0.3-cp311-cp311-win_amd64.whl',
    expectedBytes: 158763,
    sha256: '9f3bfb4965eb874431221a3ff3fdcddc7e74e3b07799e0e84ca4a0f867d449bf',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'regex-2026.9.10-cp311-cp311-win_amd64.whl',
    url:
        'https://files.pythonhosted.org/packages/0c/7f/2d39cd798871b683409cd14ab4458f60e53db86591028a8244c3155f2e92/regex-2026.9.10-cp311-cp311-win_amd64.whl',
    expectedBytes: 278263,
    sha256: 'ce7c118cb102975f974585688357a717ffbf9dddd64ab0bb1bc93eb5b367cf95',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'rich-15.0.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/82/3b/64d4899d73f91ba49a8c18a8ff3f0ea8f1c1d75481760df8c68ef5235bf5/rich-15.0.0-py3-none-any.whl',
    expectedBytes: 310654,
    sha256: '33bd4ef74232fb73fe9279a257718407f169c09b78a87ad3d296f548e27de0bb',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'safetensors-0.8.0-cp310-abi3-win_amd64.whl',
    url:
        'https://files.pythonhosted.org/packages/1b/6d/3fba214c1e5e0f69991677ec3bc17023f0421776975e1de0c682dca475e2/safetensors-0.8.0-cp310-abi3-win_amd64.whl',
    expectedBytes: 355540,
    sha256: '096ec1a98435df7beb08853bb5aa9081a84f23d0adc67ed1a0a10550f608373f',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'shellingham-1.5.4-py2.py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/e0/f9/0595336914c5619e5f28a1fb793285925a8cd4b432c9da0a987836c7f822/shellingham-1.5.4-py2.py3-none-any.whl',
    expectedBytes: 9755,
    sha256: '7ecfff8f2fd72616f7481040475a65b2bf8af90a56c89140852d1120324e8686',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'sympy-1.14.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/a2/09/77d55d46fd61b4a135c444fc97158ef34a095e5681d0a6c10b75bf356191/sympy-1.14.0-py3-none-any.whl',
    expectedBytes: 6299353,
    sha256: 'e091cc3e99d2141a0ba2847328f5479b05d94a6635cb96148ccb3f34671bd8f5',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'tokenizers-0.22.2-cp39-abi3-win_amd64.whl',
    url:
        'https://files.pythonhosted.org/packages/65/71/0670843133a43d43070abeb1949abfdef12a86d490bea9cd9e18e37c5ff7/tokenizers-0.22.2-cp39-abi3-win_amd64.whl',
    expectedBytes: 2747786,
    sha256: 'c9ea31edff2968b44a88f97d784c2f16dc0729b8b143ed004699ebca91f05c48',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'torch-2.8.0+cu128-cp311-cp311-win_amd64.whl',
    url:
        'https://download.pytorch.org/whl/cu128/torch-2.8.0%2Bcu128-cp311-cp311-win_amd64.whl',
    expectedBytes: 3461420395,
    sha256: '34c55443aafd31046a7963b63d30bc3b628ee4a704f826796c865fdfd05bb596',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'tqdm-4.70.1-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/a7/03/921a3d3c75785aca9ebfbfcabfbc3a1be12e2ab5265deb026d55a5a3f83e/tqdm-4.70.1-py3-none-any.whl',
    expectedBytes: 80199,
    sha256: 'c293e525e6fef9c20e8728fd4612df02a0aa31bb5fe91ecd93e123b1b7bffa73',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'transformers-5.0.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/52/f3/ac976fa8e305c9e49772527e09fbdc27cc6831b8a2f6b6063406626be5dd/transformers-5.0.0-py3-none-any.whl',
    expectedBytes: 10142091,
    sha256: '587086f249ce64c817213cf36afdb318d087f790723e9b3d4500b97832afd52d',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'typer-0.27.2-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/dc/bf/205d0004930ede8f542fb58f601526fccf4ae7626075ca1e6c4de5d3d652/typer-0.27.2-py3-none-any.whl',
    expectedBytes: 123130,
    sha256: 'b3a5fc4342d5fc8fda8fc3010b1cf117e9249aab7fae800c2eff62fd3842d97d',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'typer_slim-0.24.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/a7/24/5480c20380dfd18cf33d14784096dca45a24eae6102e91d49a718d3b6855/typer_slim-0.24.0-py3-none-any.whl',
    expectedBytes: 3394,
    sha256: 'd5d7ee1ee2834d5020c7c616ed5e0d0f29b9a4b1dd283bdebae198ec09778d0e',
    role: MangaOcrModelRole.runtime,
  ),
  MangaOcrModelFile(
    fileName: 'typing_extensions-4.16.0-py3-none-any.whl',
    url:
        'https://files.pythonhosted.org/packages/49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl',
    expectedBytes: 45571,
    sha256: '481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8',
    role: MangaOcrModelRole.runtime,
  ),
];

/// Original Apache-2.0 recognizer assets. Read vocab.txt for decode only;
/// do not instantiate the Japanese Mecab tokenizer (no fugashi/unidic needed).
const List<MangaOcrModelFile> kMangaOcrCudaRecognizerManifest =
    <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'config.json',
    url:
        'https://huggingface.co/kha-white/manga-ocr-base/resolve/aa6573bd10b0d446cbf622e29c3e084914df9741/config.json',
    expectedBytes: 77546,
    sha256: '8c0e395de8fa699daaac21aee33a4ba9bd1309cfbff03147813d2a025f39f349',
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'preprocessor_config.json',
    url:
        'https://huggingface.co/kha-white/manga-ocr-base/resolve/aa6573bd10b0d446cbf622e29c3e084914df9741/preprocessor_config.json',
    expectedBytes: 228,
    sha256: 'af4eb4d79cf61b47010fc0bc9352ee967579c417423b4917188d809b7e048948',
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'pytorch_model.bin',
    url:
        'https://huggingface.co/kha-white/manga-ocr-base/resolve/aa6573bd10b0d446cbf622e29c3e084914df9741/pytorch_model.bin',
    expectedBytes: 444135475,
    sha256: 'c63e0bb5b3ff798c5991de18a8e0956c7ee6d1563aca6729029815eda6f5c2eb',
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'special_tokens_map.json',
    url:
        'https://huggingface.co/kha-white/manga-ocr-base/resolve/aa6573bd10b0d446cbf622e29c3e084914df9741/special_tokens_map.json',
    expectedBytes: 112,
    sha256: '303df45a03609e4ead04bc3dc1536d0ab19b5358db685b6f3da123d05ec200e3',
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'tokenizer_config.json',
    url:
        'https://huggingface.co/kha-white/manga-ocr-base/resolve/aa6573bd10b0d446cbf622e29c3e084914df9741/tokenizer_config.json',
    expectedBytes: 486,
    sha256: 'd775ad1deac162dc56b84e9b8638f95ed8a1f263d0f56f4f40834e26e205e266',
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'vocab.txt',
    url:
        'https://huggingface.co/kha-white/manga-ocr-base/resolve/aa6573bd10b0d446cbf622e29c3e084914df9741/vocab.txt',
    expectedBytes: 24072,
    sha256: '344fbb6b8bf18c57839e924e2c9365434697e0227fac00b88bb4899b78aa594d',
    role: MangaOcrModelRole.recognizer,
  ),
];

/// Complete offline pip input; installed packages are checked after installation.
const String kMangaOcrCudaRequirements = '''
Jinja2==3.1.6 --hash=sha256:85ece4451f492d0c13c5dd7c13a64681a86afae63a5f347908daf103ce6d2f67
MarkupSafe==3.0.3 --hash=sha256:de8a88e63464af587c950061a5e6a67d3632e36df62b986892331d4620a35c01
PyYAML==6.0.3 --hash=sha256:9f3bfb4965eb874431221a3ff3fdcddc7e74e3b07799e0e84ca4a0f867d449bf
Pygments==2.21.0 --hash=sha256:2363c69b61c4a97c838da3b130dcd6468f4848992b21a82f2a63ec34377137d9
annotated-doc==0.0.5 --hash=sha256:117bac03a25ede5df5440e855b32d556049ca169ead221505badf432fed4b101
anyio==4.15.1 --hash=sha256:6152fdbbf9a77fdec97731721bebf7c4c44f7c29b424b0065826173efc7ed101
certifi==2026.7.22 --hash=sha256:62f22742b58a1a33014a2b6b706588a8d7e2a88ae7bd1a6ebe8c992928483775
click==8.5.0 --hash=sha256:255bc9599cf7748b4b1a446ccc735421bd08a2ae529a8b88597d3de5664ee360
colorama==0.4.6 --hash=sha256:4f1d9991f5acc0ca119f9d443620b77f9d6b33703e51011c16baf57afb285fc6
filelock==4.0.1 --hash=sha256:481a321a27bef441e23c53371c6abc8d7d16e26b97090074ba44f7538a3fd55a
fsspec==2026.9.0 --hash=sha256:8dd6e646e99ea382bd85f97a45e6b526a442d79423a7dc673f1e2756d05fcb5f
h11==0.16.0 --hash=sha256:63cf8bbe7522de3bf65932fda1d9c2772064ffb3dae62d55932da54b31cb6c86
hf-xet==1.6.0 --hash=sha256:fb4fadde1b2b70bf4c0c14a6dccbe7194b1c28947fefd5bbe3fed9d940676c3b
httpcore==1.0.9 --hash=sha256:2d400746a40668fc9dec9810239072b40b4484b640a8c38fd654a024c7a1bf55
httpx==0.28.1 --hash=sha256:d909fcccc110f8c7faf814ca82a9a4d816bc5a6dbfea25d6591d6985b8ba59ad
huggingface_hub==1.32.0 --hash=sha256:b0c7c80561969d9cdacdd55fce67ba9584cca0b9d4ea80957a3a5c1445fac5c8
idna==3.20 --hash=sha256:ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c
jaconv==0.5.0 --hash=sha256:2914114fe761ca49fc7089e25e6ad4a400c26f262ffce84e13b176916b71610a
markdown-it-py==4.2.0 --hash=sha256:9f7ebbcd14fe59494226453aed97c1070d83f8d24b6fc3a3bcf9a38092641c4a
mdurl==0.1.2 --hash=sha256:84008a41e51615a49fc9966191ff91509e3c40b939176e643fd50a5c2196b8f8
mpmath==1.3.0 --hash=sha256:a0b2b9fe80bbcd81a6647ff13108738cfb482d481d826cc0e02f5b35e5c88d2c
networkx==3.6.1 --hash=sha256:d47fbf302e7d9cbbb9e2555a0d267983d2aa476bac30e90dfbe5669bd57f3762
numpy==2.4.6 --hash=sha256:1e254a00cdf42b1e4d5b3d68d33af63268d41340d8885df2ab6470f2e1500147
packaging==26.3 --hash=sha256:d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c
pillow==12.3.0 --hash=sha256:8e95e1385e4998ae9694eeaa4730ba5457ff61185b3a55e2e7bea0880aef452a
pip==25.3 --hash=sha256:9655943313a94722b7774661c21049070f6bbb0a1516bf02f7c8d5d9201514cd
regex==2026.9.10 --hash=sha256:ce7c118cb102975f974585688357a717ffbf9dddd64ab0bb1bc93eb5b367cf95
rich==15.0.0 --hash=sha256:33bd4ef74232fb73fe9279a257718407f169c09b78a87ad3d296f548e27de0bb
safetensors==0.8.0 --hash=sha256:096ec1a98435df7beb08853bb5aa9081a84f23d0adc67ed1a0a10550f608373f
shellingham==1.5.4 --hash=sha256:7ecfff8f2fd72616f7481040475a65b2bf8af90a56c89140852d1120324e8686
sympy==1.14.0 --hash=sha256:e091cc3e99d2141a0ba2847328f5479b05d94a6635cb96148ccb3f34671bd8f5
tokenizers==0.22.2 --hash=sha256:c9ea31edff2968b44a88f97d784c2f16dc0729b8b143ed004699ebca91f05c48
torch==2.8.0+cu128 --hash=sha256:34c55443aafd31046a7963b63d30bc3b628ee4a704f826796c865fdfd05bb596
tqdm==4.70.1 --hash=sha256:c293e525e6fef9c20e8728fd4612df02a0aa31bb5fe91ecd93e123b1b7bffa73
transformers==5.0.0 --hash=sha256:587086f249ce64c817213cf36afdb318d087f790723e9b3d4500b97832afd52d
typer-slim==0.24.0 --hash=sha256:d5d7ee1ee2834d5020c7c616ed5e0d0f29b9a4b1dd283bdebae198ec09778d0e
typer==0.27.2 --hash=sha256:b3a5fc4342d5fc8fda8fc3010b1cf117e9249aab7fae800c2eff62fd3842d97d
typing_extensions==4.16.0 --hash=sha256:481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8
''';

/// Shared detector and original-resolution horizontal line route, also pinned
/// and hashed so every asset in the CUDA tier has the same integrity contract.
const List<MangaOcrModelFile> kMangaOcrCudaRoutingManifest =
    <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url:
        'https://huggingface.co/ogkalu/comic-text-and-bubble-detector/resolve/16e8a622f91fabc6b5b65c96d32d1183f8843546/detector-v4-s_int8.onnx',
    expectedBytes: 11120765,
    sha256: '5fe9e4f576e49d4e7e8b0e029d6d3cdc252abd4694113e1cae120e62c931ea79',
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: 'ppocrv6_small_det.onnx',
    url:
        'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx/resolve/28fe5895c24fd108c19eb3e8479f4ab385fbfc62/inference.onnx',
    expectedBytes: 9880512,
    sha256: 'd73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e',
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'ppocrv6_small_rec.onnx',
    url:
        'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/resolve/b8f84f0b80c529de40b4fbb3544b84fa7233a513/inference.onnx',
    expectedBytes: 21159378,
    sha256: '5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634',
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'ppocrv6_small_rec.yml',
    url:
        'https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/resolve/b8f84f0b80c529de40b4fbb3544b84fa7233a513/inference.yml',
    expectedBytes: 150579,
    sha256: 'ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1',
    role: MangaOcrModelRole.recognizer,
  ),
];

/// Complete download set for the selectable Windows CUDA OCR tier.
const List<MangaOcrModelFile> kMangaOcrCudaModelManifest = <MangaOcrModelFile>[
  ...kMangaOcrCudaRoutingManifest,
  ...kMangaOcrCudaRecognizerManifest,
  ...kMangaOcrCudaRuntimeManifest,
];
