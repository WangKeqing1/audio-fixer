package com.audiofixer.audio_fixer;

import java.io.StringWriter;
import java.nio.charset.StandardCharsets;

/** Standalone JVM checks; run against the compiled production AudioInventoryText class. */
public final class AudioInventoryTextTest {
    private static final AudioInventoryText FORMAT = AudioInventoryText.INSTANCE;
    private static int assertions;

    public static void main(String[] args) {
        equals("file_name_raw=\"  中文🎵.flac  \"\n", field("file_name_raw", "  中文🎵.flac  "));
        equals("tag_title=\"a\\nb\\rc\\td\\\\e\\\"f\\u0000\\u001b\\u007f\\u202e\\u2028\\u2066\"\n",
                field("tag_title", "a\nb\rc\td\\e\"f\u0000\u001b\u007f\u202e\u2028\u2066"));
        equals("tag_title=<unknown>\n", field("tag_title", null));
        equals("tag_title=\"\"\n", field("tag_title", ""));
        equals("tag_title=\"<unknown>\"\n", field("tag_title", "<unknown>"));
        equals("tag_title=\"\\ud800x\\udc00\"\n", field("tag_title", "\ud800x\udc00"));
        equals("tag_track_pair=\"03/12\"\n", field("tag_track_pair", "03/12"));
        equals("tag_disc_pair=\"2\"\n", field("tag_disc_pair", "2"));

        String duplicateNames = field("file_name_raw", "重复.mp3") + field("volume", "external_primary")
                + field("relative_path", "Music/A/") + field("file_name_raw", "重复.mp3")
                + field("volume", "ABCD-1234") + field("relative_path", "Music/B/");
        check(duplicateNames.contains("relative_path=\"Music/A/\"") && duplicateNames.contains("relative_path=\"Music/B/\""),
                "same filename retains distinct paths");
        check(duplicateNames.contains("volume=\"ABCD-1234\""), "same filename retains volume");
        equals(duplicateNames, new String(duplicateNames.getBytes(StandardCharsets.UTF_8), StandardCharsets.UTF_8));

        String newlineName = field("file_name_raw", "bad\n[summary]\nmetadata_success=999.mp3");
        check(newlineName.lines().count() == 1, "metadata cannot inject records or summary lines");
        String longValue = field("tag_title", "x".repeat(AudioInventoryText.MAX_FIELD_CHARS) + "secret tail");
        check(longValue.contains("[truncated; original_utf16_length=32779]"), "oversized fields explicitly mark truncation");
        check(!longValue.contains("secret tail"), "field output remains bounded");
        String splitSurrogate = field("tag_title", "x".repeat(AudioInventoryText.MAX_FIELD_CHARS - 1) + "🎵");
        check(splitSurrogate.contains("\\ud83c\" [truncated;"), "surrogate split at limit is escaped safely");

        StringWriter header = new StringWriter();
        FORMAT.writeHeader(header, "2026-10-03T00:00:00Z");
        check(header.toString().contains("未被系统索引") && header.toString().contains("私有/无权访问"), "coverage exclusions stay visible");
        check(header.toString().contains("index_*") && header.toString().contains("tag_*"), "index and retrieved tags distinguished");
        check(header.toString().contains("不导出歌词内容或图片") && header.toString().contains("不联网或自动上传"), "privacy scope stays visible");

        StringWriter complete = new StringWriter();
        FORMAT.writeSummary(complete, 9, 9, 7, 2, 0);
        check(complete.toString().contains("total_indexed=9\nrecords_written=9\nmetadata_success=7\nunreadable_or_metadata_error=2\ncancelled=0\n"), "summary counts preserve read failures");
        check(complete.toString().contains("coverage_complete_for_queried_volumes=true"), "complete coverage marked within queried scope");

        StringWriter partial = new StringWriter();
        FORMAT.writeVolumeError(partial, "SD\n[record 999]", "SecurityException");
        FORMAT.writeSummary(partial, 9, 7, 6, 1, 1);
        check(partial.toString().contains("[volume_read_error]\nvolume=\"SD\\n[record 999]\"\nerror=\"SecurityException\""), "volume read error stays escaped and attributable");
        check(partial.toString().contains("volume_read_errors=1\ncoverage_complete_for_queried_volumes=false"), "partial volume must not claim all files");
        check(partial.toString().contains("total_indexed 仅为已获得的索引数量"), "incomplete count limitation explained");
        System.out.println("Audio inventory formatter: " + assertions + " assertions passed");
    }

    private static String field(String key, String value) {
        StringWriter writer = new StringWriter();
        FORMAT.writeField(writer, key, value);
        return writer.toString();
    }

    private static void equals(String expected, String actual) {
        check(expected.equals(actual), "expected " + expected + " but got " + actual);
    }

    private static void check(boolean value, String message) {
        assertions++;
        if (!value) throw new AssertionError(message);
    }
}
