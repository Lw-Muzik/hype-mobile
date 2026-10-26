package x.a.zix;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;

/**
 * Makes a MediaMuxer MP4 readable by JAudioTagger.
 *
 * Samsung's MediaMuxer writes, inside {@code moov}, a vendor {@code udta}
 * box (SDLN/smrd/smta) followed by an Android QuickTime-style {@code meta}
 * box that has no version/flags field. JAudioTagger finds {@code udta}, looks
 * for {@code meta} past its end (in the sibling), assumes four version bytes
 * and reads "hdlr" as a length: NullBoxIdException, and the file is rejected.
 *
 * Neither box carries anything the app needs, so every DIRECT child of
 * {@code moov} typed {@code udta} or {@code meta} is retyped {@code free}
 * (4 bytes, in place). Sizes are untouched, so no offset moves.
 */
final class Mp4BoxRetyper {

    private Mp4BoxRetyper() {}

    private static final int MOOV = 0x6d6f6f76; // "moov"
    private static final int UDTA = 0x75647461; // "udta"
    private static final int META = 0x6d657461; // "meta"
    private static final int FREE = 0x66726565; // "free"

    /**
     * Retypes the udta/meta children of moov in {@code file}. Returns a short
     * human-readable outcome ("retyped 2 box(es): udta,meta", "nothing to
     * retype", or "left untouched: why"); never throws for a malformed layout,
     * which is left exactly as it was.
     */
    static String retype(File file) throws IOException {
        try (RandomAccessFile f = new RandomAccessFile(file, "rw")) {
            final long length = f.length();
            long moovStart = -1;
            long moovEnd = -1;

            long pos = 0;
            while (pos + 8 <= length) {
                long[] box = header(f, pos, length);
                if (box == null) return "left untouched: bad top-level box at " + pos;
                if (box[1] == MOOV) {
                    moovStart = pos + box[2];
                    moovEnd = pos + box[0];
                    break;
                }
                pos += box[0];
            }
            if (moovStart < 0) return "left untouched: no moov box";

            int count = 0;
            StringBuilder names = new StringBuilder();
            long[] offsets = new long[64];
            pos = moovStart;
            while (pos + 8 <= moovEnd) {
                long[] box = header(f, pos, moovEnd);
                if (box == null) return "left untouched: bad box inside moov at " + pos;
                if (box[1] == UDTA || box[1] == META) {
                    if (count == offsets.length) return "left untouched: too many udta/meta boxes";
                    offsets[count++] = pos + 4;
                    if (names.length() > 0) names.append(',');
                    names.append(box[1] == UDTA ? "udta" : "meta");
                }
                pos += box[0];
            }
            // Validate the whole of moov first, so a layout that goes wrong
            // half-way never leaves a half-retyped file.
            if (count == 0) return "nothing to retype";
            for (int i = 0; i < count; i++) {
                f.seek(offsets[i]);
                f.writeInt(FREE);
            }
            return "retyped " + count + " box(es): " + names;
        }
    }

    /**
     * Reads the box header at {@code pos}, bounded by {@code end}. Returns
     * {total size, type, header length}, or null when it is not a sane box.
     */
    private static long[] header(RandomAccessFile f, long pos, long end) throws IOException {
        f.seek(pos);
        long size = f.readInt() & 0xFFFFFFFFL;
        int type = f.readInt();
        long headerLength = 8;
        if (size == 1) {
            if (pos + 16 > end) return null;
            size = f.readLong();
            headerLength = 16;
        } else if (size == 0) {
            size = end - pos;
        }
        if (size < headerLength || size < 0 || pos + size > end) return null;
        return new long[] {size, type, headerLength};
    }
}
