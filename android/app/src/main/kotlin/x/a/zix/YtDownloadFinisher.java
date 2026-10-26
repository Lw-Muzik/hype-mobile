package x.a.zix;

import android.content.ContentResolver;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.net.Uri;
import android.util.Log;

import org.jaudiotagger.audio.AudioFile;
import org.jaudiotagger.audio.AudioFileIO;
import org.jaudiotagger.tag.FieldKey;
import org.jaudiotagger.tag.Tag;
import org.jaudiotagger.tag.images.ArtworkFactory;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Turns a YouTube download into a proper music file.
 *
 * YouTube serves audio as a streaming (DASH, fragmented) MP4: no tags, and a
 * layout tag writers can't edit — JAudioTagger writes into it and then fails
 * its own check ("incorrect offsets written"). So, as yt-dlp does, it is first
 * repackaged into a plain MP4 (the AAC copied as is, no re-encode), and the
 * tags — title, artists, album, year, track, lyrics, cover — go into that.
 */
public final class YtDownloadFinisher {

    static {
        Logger.getLogger("org.jaudiotagger").setLevel(Level.OFF);
    }

    private YtDownloadFinisher() {}

    /**
     * Writes {@code src} repackaged and tagged to {@code dst} (which must end in
     * .m4a). Returns null on success, else what went wrong; {@code dst} is
     * removed on failure.
     */
    public static String finish(String src, String dst, Map<String, Object> tags) {
        File out = new File(dst);
        try {
            remux(src, dst);
            // Samsung's muxer leaves boxes JAudioTagger can't parse; without
            // this the tagger throws and the track would stay raw.
            Log.i("YtDownloadFinisher", "moov: " + Mp4BoxRetyper.retype(out));
            tag(out, tags);
            return null;
        } catch (Throwable e) {
            //noinspection ResultOfMethodCallIgnored
            out.delete();
            return e.toString();
        }
    }

    /** Copies the audio samples into a plain MP4, timestamps rebased to 0. */
    static void remux(String src, String dst) throws IOException {
        MediaExtractor extractor = new MediaExtractor();
        MediaMuxer muxer = null;
        boolean started = false;
        try {
            extractor.setDataSource(src);
            int track = -1;
            MediaFormat format = null;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat f = extractor.getTrackFormat(i);
                String mime = f.getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("audio/")) {
                    track = i;
                    format = f;
                    break;
                }
            }
            if (track < 0) throw new IOException("no audio track");
            extractor.selectTrack(track);
            muxer = new MediaMuxer(dst, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            int out = muxer.addTrack(format);
            muxer.start();
            started = true;

            int capacity = 256 * 1024;
            if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                capacity = Math.max(capacity, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE));
            }
            ByteBuffer buffer = ByteBuffer.allocateDirect(capacity);
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            long first = Long.MIN_VALUE;
            int samples = 0;
            while (true) {
                buffer.clear();
                int size = extractor.readSampleData(buffer, 0);
                if (size < 0) break;
                long time = extractor.getSampleTime();
                if (first == Long.MIN_VALUE) first = time;
                int flags = (extractor.getSampleFlags() & MediaExtractor.SAMPLE_FLAG_SYNC) != 0
                        ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0;
                info.set(0, size, Math.max(0, time - first), flags);
                muxer.writeSampleData(out, buffer, info);
                samples++;
                extractor.advance();
            }
            if (samples == 0) throw new IOException("no audio samples");
            muxer.stop();
            started = false;
        } finally {
            if (muxer != null) {
                try {
                    if (started) muxer.stop();
                } catch (Exception ignored) {
                }
                try {
                    muxer.release();
                } catch (Exception ignored) {
                }
            }
            extractor.release();
        }
    }

    static void tag(File file, Map<String, Object> tags) throws Exception {
        AudioFile audio = AudioFileIO.read(file);
        Tag tag = audio.getTagOrCreateAndSetDefault();
        set(tag, FieldKey.TITLE, tags.get("title"));
        set(tag, FieldKey.ARTIST, tags.get("artist"));
        set(tag, FieldKey.ALBUM, tags.get("album"));
        set(tag, FieldKey.ALBUM_ARTIST, tags.get("albumArtist"));
        set(tag, FieldKey.YEAR, tags.get("year"));
        set(tag, FieldKey.TRACK, tags.get("track"));
        set(tag, FieldKey.TRACK_TOTAL, tags.get("trackTotal"));
        set(tag, FieldKey.LYRICS, tags.get("lyrics"));
        Object cover = tags.get("coverPath");
        if (cover instanceof String && !((String) cover).isEmpty()) {
            File art = new File((String) cover);
            if (Boolean.TRUE.equals(tags.get("cropCover"))) art = cropSquare(art);
            if (art != null && art.isFile() && art.length() > 0) {
                tag.deleteArtworkField();
                tag.setField(ArtworkFactory.createArtworkFromFile(art));
            }
        }
        audio.commit();
    }

    private static void set(Tag tag, FieldKey key, Object value) {
        if (!(value instanceof String) || ((String) value).trim().isEmpty()) return;
        try {
            tag.setField(key, (String) value);
        } catch (Exception ignored) {
            // One field the format refuses is not worth the rest of the tags.
        }
    }

    /** Longest cover decode we allow: the short side stays at least this many px. */
    private static final int MAX_COVER_SIDE = 1200;

    /** Largest power-of-two sample size that keeps the short side >= {@code minSide}. */
    static int sampleSizeFor(int w, int h, int minSide) {
        int shortSide = Math.min(w, h);
        int sample = 1;
        while (shortSide / (sample * 2) >= minSide) sample *= 2;
        return sample;
    }

    /** A 16:9 video thumbnail's middle square, as a JPEG beside it. */
    static File cropSquare(File src) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(src.getPath(), bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null;
        if (bounds.outWidth == bounds.outHeight) return src;
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, MAX_COVER_SIDE);
        Bitmap bitmap = BitmapFactory.decodeFile(src.getPath(), opts);
        if (bitmap == null) return null;
        int w = bitmap.getWidth();
        int h = bitmap.getHeight();
        if (w == h) return src;
        int side = Math.min(w, h);
        Bitmap square = Bitmap.createBitmap(bitmap, (w - side) / 2, (h - side) / 2, side, side);
        File out = new File(src.getParentFile(), "square_" + src.getName());
        try (OutputStream os = new FileOutputStream(out)) {
            square.compress(Bitmap.CompressFormat.JPEG, 92, os);
            return out;
        } catch (IOException e) {
            return null;
        } finally {
            if (square != bitmap) square.recycle();
            bitmap.recycle();
        }
    }

    /** A plain file copy (a path outside MediaStore). False when it failed. */
    static boolean copyFile(File src, File dst) {
        try (InputStream in = new FileInputStream(src);
             OutputStream out = new FileOutputStream(dst)) {
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    /**
     * Replaces the content of a MediaStore item with {@code src}. Throws
     * SecurityException when the app may not write it (another app's file:
     * ask with MediaStore.createWriteRequest first).
     */
    static void copyToUri(ContentResolver resolver, Uri uri, File src) throws IOException {
        try (InputStream in = new FileInputStream(src);
             OutputStream out = resolver.openOutputStream(uri, "wt")) {
            if (out == null) throw new IOException("no output stream for " + uri);
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        }
    }
}
