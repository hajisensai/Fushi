//! 按文件头识别容器（不看扩展名）。

use std::io::{Read, SeekFrom};

use crate::{ReadSeek, ThumbError};

/// 能出封面的容器种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContainerKind {
    /// zip：cbz 或 epub（进一步区分要看目录，见 [`crate::extract`]）。
    Zip,
    /// RAR 1.5–4.x（`Rar!\x1A\x07\x00`）。
    Rar4,
    /// RAR 5（`Rar!\x1A\x07\x01\x00`）。
    Rar5,
    SevenZip,
    Pdf,
}

/// PDF 规范允许 `%PDF-` 之前有垃圾字节（实务中最多 1024 字节）。
const PDF_HEADER_WINDOW: usize = 1024;

/// 识别容器；读完把游标放回开头。
pub fn sniff(reader: &mut dyn ReadSeek) -> Result<ContainerKind, ThumbError> {
    reader.seek(SeekFrom::Start(0))?;
    let mut head = Vec::with_capacity(PDF_HEADER_WINDOW);
    (&mut *reader)
        .take(PDF_HEADER_WINDOW as u64)
        .read_to_end(&mut head)?;
    reader.seek(SeekFrom::Start(0))?;
    classify(&head).ok_or(ThumbError::UnknownFormat)
}

/// 纯函数版本：只看给定的文件头字节。
pub fn classify(head: &[u8]) -> Option<ContainerKind> {
    if head.starts_with(b"PK\x03\x04") || head.starts_with(b"PK\x05\x06") {
        return Some(ContainerKind::Zip);
    }
    if head.starts_with(b"Rar!\x1A\x07\x01\x00") {
        return Some(ContainerKind::Rar5);
    }
    if head.starts_with(b"Rar!\x1A\x07\x00") {
        return Some(ContainerKind::Rar4);
    }
    if head.starts_with(b"7z\xBC\xAF\x27\x1C") {
        return Some(ContainerKind::SevenZip);
    }
    if head.windows(5).any(|w| w == b"%PDF-") {
        return Some(ContainerKind::Pdf);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn classifies_known_magic() {
        assert_eq!(classify(b"PK\x03\x04rest"), Some(ContainerKind::Zip));
        assert_eq!(classify(b"PK\x05\x06"), Some(ContainerKind::Zip));
        assert_eq!(
            classify(b"Rar!\x1A\x07\x01\x00..."),
            Some(ContainerKind::Rar5)
        );
        assert_eq!(classify(b"Rar!\x1A\x07\x00..."), Some(ContainerKind::Rar4));
        assert_eq!(
            classify(b"7z\xBC\xAF\x27\x1C\x00\x04"),
            Some(ContainerKind::SevenZip)
        );
        assert_eq!(classify(b"%PDF-1.7\n"), Some(ContainerKind::Pdf));
    }

    #[test]
    fn pdf_header_may_follow_leading_garbage() {
        let mut data = vec![b'x'; 300];
        data.extend_from_slice(b"%PDF-1.4");
        assert_eq!(classify(&data), Some(ContainerKind::Pdf));
    }

    #[test]
    fn unknown_and_empty_inputs_are_rejected() {
        assert_eq!(classify(b""), None);
        assert_eq!(classify(b"plain text novel"), None);
        let mut empty = Cursor::new(Vec::<u8>::new());
        assert_eq!(sniff(&mut empty), Err(ThumbError::UnknownFormat));
    }

    #[test]
    fn sniff_rewinds_the_reader() {
        let mut c = Cursor::new(b"%PDF-1.7 body".to_vec());
        assert_eq!(sniff(&mut c), Ok(ContainerKind::Pdf));
        assert_eq!(c.position(), 0);
    }
}
