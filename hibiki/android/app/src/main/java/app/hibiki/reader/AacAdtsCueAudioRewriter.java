package app.hibiki.reader;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Converts a short MP4/M4A file (Transformer output) to raw ADTS AAC.
 * Ported from Hoshi-Reader-Android AacAdtsCueAudioRewriter.kt.
 */
final class AacAdtsCueAudioRewriter {
    private AacAdtsCueAudioRewriter() {}

    private static final int BOX_HEADER_SIZE = 8;
    private static final int EXTENDED_BOX_HEADER_SIZE = 16;
    private static final int FULL_BOX_HEADER_SIZE = 4;
    private static final int INT_SIZE = 4;
    private static final int LONG_SIZE = 8;
    private static final int AUDIO_SAMPLE_ENTRY_PAYLOAD_SIZE = 28;
    private static final int STSC_ENTRY_SIZE = 12;
    private static final int ADTS_HEADER_SIZE = 7;
    private static final int AUDIO_SPECIFIC_CONFIG_TAG = 0x05;
    private static final int MAX_REWRITE_SIZE = 100 * 1024 * 1024; // 100 MB

    static boolean rewrite(File input, File output) {
        try {
            byte[] bytes = readAllBytes(input);
            List<Box> topBoxes = boxes(bytes, 0, bytes.length);
            Box moov = null;
            for (Box b : topBoxes) {
                if ("moov".equals(b.type)) { moov = b; break; }
            }
            if (moov == null) return false;

            Box stbl = findAudioSampleTable(bytes, moov);
            if (stbl == null) return false;

            int[] aacConfig = readAacConfig(bytes, stbl);
            if (aacConfig == null) return false;
            int profile = aacConfig[0], sampleRateIndex = aacConfig[1], channelConfig = aacConfig[2];

            int[] sampleSizes = readSampleSizes(bytes, stbl);
            int[] chunkOffsets = readChunkOffsets(bytes, stbl);
            int[] chunkSamples = readChunkSamples(bytes, stbl, chunkOffsets.length);
            if (sampleSizes.length == 0 || chunkOffsets.length == 0 || chunkSamples.length == 0) {
                return false;
            }

            ByteArrayOutputStream out = new ByteArrayOutputStream(bytes.length);
            int sampleIndex = 0;
            for (int chunkIndex = 0; chunkIndex < chunkOffsets.length; chunkIndex++) {
                int sampleOffset = chunkOffsets[chunkIndex];
                for (int s = 0; s < chunkSamples[chunkIndex]; s++) {
                    if (sampleIndex >= sampleSizes.length) return false;
                    int sampleSize = sampleSizes[sampleIndex++];
                    if (sampleSize <= 0 || sampleOffset < 0 || sampleOffset + sampleSize > bytes.length) {
                        return false;
                    }
                    out.write(adtsHeader(profile, sampleRateIndex, channelConfig, sampleSize + ADTS_HEADER_SIZE));
                    out.write(bytes, sampleOffset, sampleSize);
                    sampleOffset += sampleSize;
                }
            }
            if (sampleIndex != sampleSizes.length) return false;

            File parent = output.getParentFile();
            if (parent != null) parent.mkdirs();
            writeAllBytes(output, out.toByteArray());
            return output.isFile() && output.length() > 0;
        } catch (Exception e) {
            android.util.Log.e("hibiki-audio", "ADTS rewrite failed", e);
            return false;
        }
    }

    private static Box findAudioSampleTable(byte[] bytes, Box moov) {
        for (Box trak : boxes(bytes, moov.contentStart, moov.end)) {
            if (!"trak".equals(trak.type)) continue;
            Box mdia = child(bytes, trak, "mdia");
            if (mdia == null) continue;
            Box handler = child(bytes, mdia, "hdlr");
            if (handler == null || !"soun".equals(handlerType(bytes, handler))) continue;
            Box minf = child(bytes, mdia, "minf");
            if (minf == null) continue;
            return child(bytes, minf, "stbl");
        }
        return null;
    }

    private static int[] readAacConfig(byte[] bytes, Box stbl) {
        Box stsd = child(bytes, stbl, "stsd");
        if (stsd == null) return null;
        int entryStart = stsd.contentStart + FULL_BOX_HEADER_SIZE + INT_SIZE;
        if (entryStart + BOX_HEADER_SIZE > stsd.end) return null;
        if (!"mp4a".equals(type(bytes, entryStart + INT_SIZE))) return null;
        int mp4aSize = (int) uint32(bytes, entryStart);
        int mp4aEnd = Math.min(entryStart + mp4aSize, stsd.end);
        int esdsStart = entryStart + BOX_HEADER_SIZE + AUDIO_SAMPLE_ENTRY_PAYLOAD_SIZE;
        Box esds = null;
        for (Box b : boxes(bytes, esdsStart, mp4aEnd)) {
            if ("esds".equals(b.type)) { esds = b; break; }
        }
        if (esds == null) return null;
        byte[] asc = findAudioSpecificConfig(bytes, esds.contentStart + FULL_BOX_HEADER_SIZE, esds.end);
        if (asc == null) return null;
        return aacConfig(asc);
    }

    private static byte[] findAudioSpecificConfig(byte[] bytes, int start, int end) {
        int pos = start;
        while (pos < end - 2) {
            if ((bytes[pos] & 0xff) == AUDIO_SPECIFIC_CONFIG_TAG) {
                int[] length = descriptorLength(bytes, pos + 1, end);
                if (length == null) { pos++; continue; }
                int payloadStart = length[0];
                int payloadLength = length[1];
                if (payloadLength >= 2 && payloadStart + payloadLength <= end) {
                    byte[] result = new byte[payloadLength];
                    System.arraycopy(bytes, payloadStart, result, 0, payloadLength);
                    return result;
                }
            }
            pos++;
        }
        return null;
    }

    private static int[] readSampleSizes(byte[] bytes, Box stbl) {
        Box stsz = child(bytes, stbl, "stsz");
        if (stsz == null) return new int[0];
        int sampleSize = (int) uint32(bytes, stsz.contentStart + FULL_BOX_HEADER_SIZE);
        int sampleCount = (int) uint32(bytes, stsz.contentStart + FULL_BOX_HEADER_SIZE + INT_SIZE);
        if (sampleCount <= 0) return new int[0];
        if (sampleSize > 0) {
            int[] sizes = new int[sampleCount];
            Arrays.fill(sizes, sampleSize);
            return sizes;
        }
        int start = stsz.contentStart + FULL_BOX_HEADER_SIZE + INT_SIZE + INT_SIZE;
        if (start + sampleCount * INT_SIZE > stsz.end) return new int[0];
        int[] sizes = new int[sampleCount];
        for (int i = 0; i < sampleCount; i++) {
            sizes[i] = (int) uint32(bytes, start + i * INT_SIZE);
        }
        return sizes;
    }

    private static int[] readChunkOffsets(byte[] bytes, Box stbl) {
        Box stco = child(bytes, stbl, "stco");
        if (stco != null) {
            int count = (int) uint32(bytes, stco.contentStart + FULL_BOX_HEADER_SIZE);
            int start = stco.contentStart + FULL_BOX_HEADER_SIZE + INT_SIZE;
            if (count <= 0 || start + count * INT_SIZE > stco.end) return new int[0];
            int[] offsets = new int[count];
            for (int i = 0; i < count; i++) {
                offsets[i] = (int) uint32(bytes, start + i * INT_SIZE);
            }
            return offsets;
        }
        Box co64 = child(bytes, stbl, "co64");
        if (co64 != null) {
            int count = (int) uint32(bytes, co64.contentStart + FULL_BOX_HEADER_SIZE);
            int start = co64.contentStart + FULL_BOX_HEADER_SIZE + INT_SIZE;
            if (count <= 0 || start + count * LONG_SIZE > co64.end) return new int[0];
            int[] offsets = new int[count];
            for (int i = 0; i < count; i++) {
                offsets[i] = (int) uint64(bytes, start + i * LONG_SIZE);
            }
            return offsets;
        }
        return new int[0];
    }

    private static int[] readChunkSamples(byte[] bytes, Box stbl, int chunkCount) {
        Box stsc = child(bytes, stbl, "stsc");
        if (stsc == null) return new int[0];
        int entryCount = (int) uint32(bytes, stsc.contentStart + FULL_BOX_HEADER_SIZE);
        int start = stsc.contentStart + FULL_BOX_HEADER_SIZE + INT_SIZE;
        if (entryCount <= 0 || start + entryCount * STSC_ENTRY_SIZE > stsc.end) return new int[0];
        int[] firstChunks = new int[entryCount];
        int[] samplesPerChunks = new int[entryCount];
        for (int i = 0; i < entryCount; i++) {
            int offset = start + i * STSC_ENTRY_SIZE;
            firstChunks[i] = (int) uint32(bytes, offset);
            samplesPerChunks[i] = (int) uint32(bytes, offset + INT_SIZE);
        }
        int[] result = new int[chunkCount];
        for (int chunk = 0; chunk < chunkCount; chunk++) {
            int oneBasedChunk = chunk + 1;
            int samples = 0;
            for (int i = entryCount - 1; i >= 0; i--) {
                if (firstChunks[i] <= oneBasedChunk) {
                    samples = samplesPerChunks[i];
                    break;
                }
            }
            result[chunk] = samples;
        }
        return result;
    }

    private static int[] aacConfig(byte[] asc) {
        if (asc.length < 2) return null;
        StringBuilder bits = new StringBuilder();
        for (byte b : asc) {
            String s = Integer.toBinaryString(b & 0xff);
            for (int pad = s.length(); pad < 8; pad++) bits.append('0');
            bits.append(s);
        }
        int objectType = Integer.parseInt(bits.substring(0, 5), 2);
        int sampleRateIndex = Integer.parseInt(bits.substring(5, 9), 2);
        int channelConfig = Integer.parseInt(bits.substring(9, 13), 2);
        if (objectType <= 0 || sampleRateIndex == 15 || channelConfig <= 0) return null;
        return new int[]{objectType - 1, sampleRateIndex, channelConfig};
    }

    private static byte[] adtsHeader(int profile, int sampleRateIndex, int channelConfig, int frameLength) {
        return new byte[]{
            (byte) 0xff,
            (byte) 0xf1,
            (byte) (((profile & 0x03) << 6) | ((sampleRateIndex & 0x0f) << 2) | ((channelConfig >> 2) & 0x01)),
            (byte) (((channelConfig & 0x03) << 6) | ((frameLength >> 11) & 0x03)),
            (byte) ((frameLength >> 3) & 0xff),
            (byte) (((frameLength & 0x07) << 5) | 0x1f),
            (byte) 0xfc,
        };
    }

    private static Box child(byte[] bytes, Box parent, String type) {
        for (Box b : boxes(bytes, parent.contentStart, parent.end)) {
            if (type.equals(b.type)) return b;
        }
        return null;
    }

    private static List<Box> boxes(byte[] bytes, int start, int end) {
        List<Box> result = new ArrayList<>();
        int pos = start;
        while (pos + BOX_HEADER_SIZE <= end) {
            long smallSize = uint32(bytes, pos);
            String boxType = type(bytes, pos + INT_SIZE);
            int headerSize;
            long size;
            if (smallSize == 1L) {
                if (pos + EXTENDED_BOX_HEADER_SIZE > end) break;
                headerSize = EXTENDED_BOX_HEADER_SIZE;
                size = uint64(bytes, pos + BOX_HEADER_SIZE);
            } else {
                headerSize = BOX_HEADER_SIZE;
                size = smallSize;
            }
            if (size < headerSize || pos + size > end) break;
            result.add(new Box(boxType, pos, headerSize, (int) size));
            pos += (int) size;
        }
        return result;
    }

    private static String handlerType(byte[] bytes, Box handler) {
        int offset = handler.contentStart + FULL_BOX_HEADER_SIZE + INT_SIZE;
        if (offset + INT_SIZE <= handler.end) return type(bytes, offset);
        return null;
    }

    private static int[] descriptorLength(byte[] bytes, int start, int end) {
        int pos = start;
        int length = 0;
        for (int i = 0; i < 4; i++) {
            if (pos >= end) return null;
            int value = bytes[pos++] & 0xff;
            length = (length << 7) | (value & 0x7f);
            if ((value & 0x80) == 0) return new int[]{pos, length};
        }
        return null;
    }

    private static String type(byte[] bytes, int offset) {
        return new String(bytes, offset, INT_SIZE, StandardCharsets.ISO_8859_1);
    }

    private static long uint32(byte[] bytes, int offset) {
        return ((long) (bytes[offset] & 0xff) << 24)
            | ((long) (bytes[offset + 1] & 0xff) << 16)
            | ((long) (bytes[offset + 2] & 0xff) << 8)
            | ((long) (bytes[offset + 3] & 0xff));
    }

    private static long uint64(byte[] bytes, int offset) {
        long value = 0;
        for (int i = 0; i < LONG_SIZE; i++) {
            value = (value << 8) | (bytes[offset + i] & 0xffL);
        }
        return value;
    }

    private static byte[] readAllBytes(File file) throws IOException {
        long len = file.length();
        if (len > MAX_REWRITE_SIZE) {
            throw new IOException("File too large for ADTS rewrite: "
                + len + " bytes (max " + MAX_REWRITE_SIZE + ")");
        }
        try (FileInputStream fis = new FileInputStream(file)) {
            byte[] data = new byte[(int) len];
            int offset = 0;
            while (offset < data.length) {
                int read = fis.read(data, offset, data.length - offset);
                if (read < 0) break;
                offset += read;
            }
            return data;
        }
    }

    private static void writeAllBytes(File file, byte[] data) throws IOException {
        try (FileOutputStream fos = new FileOutputStream(file)) {
            fos.write(data);
        }
    }

    private static final class Box {
        final String type;
        final int start;
        final int headerSize;
        final int size;
        final int contentStart;
        final int end;

        Box(String type, int start, int headerSize, int size) {
            this.type = type;
            this.start = start;
            this.headerSize = headerSize;
            this.size = size;
            this.contentStart = start + headerSize;
            this.end = start + size;
        }
    }
}
