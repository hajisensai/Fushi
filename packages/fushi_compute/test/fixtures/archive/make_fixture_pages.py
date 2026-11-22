# 加密归档夹具的页面素材生成脚本（4x4 纯色 PNG + 一份 UTF-8 文本），夹具本身用真 7-Zip 打包：
#
#   python -I make_fixture_pages.py <src>      # 生成 <src>/卷1/{001,002,003}.png + 读我.txt
#   cd <src>
#   7z a -tzip -mem=AES256    -pfushi-pw aes256.zip            卷1
#   7z a -tzip -mem=ZipCrypto -pfushi-pw zipcrypto.zip         卷1
#   7z a -tzip                           plain.zip             卷1
#   7z a -t7z  -pfushi-pw -mhe=off       content_encrypted.7z  卷1
#   7z a -t7z  -pfushi-pw -mhe=on        header_encrypted.7z   卷1
#   7z a -t7z                            plain.7z              卷1
#
# 密码一律 `fushi-pw`。Rust（native/fushi_compute/src/archive.rs 的测试）与 Dart 测试共用这些文件。
import struct, zlib, sys
def png(path, color):
    w=h=4
    raw=b''.join(b'\x00'+bytes(color)*w for _ in range(h))
    def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
    open(path,'wb').write(data)
d=sys.argv[1]
png(d+'/卷1/001.png',(255,0,0)); png(d+'/卷1/002.png',(0,255,0)); png(d+'/卷1/003.png',(0,0,255))
open(d+'/卷1/读我.txt','w',encoding='utf-8').write('パスワード保護テスト\n'*20)
