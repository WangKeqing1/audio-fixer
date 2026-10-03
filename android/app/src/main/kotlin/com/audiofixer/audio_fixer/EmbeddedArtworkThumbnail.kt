package com.audiofixer.audio_fixer

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlin.math.max
import kotlin.math.roundToInt

/** Reads the requested file's embedded picture; never borrows album-level art. */
internal object EmbeddedArtworkThumbnail {
    private const val THUMBNAIL_SIZE = 192
    private const val MAX_EMBEDDED_BYTES = 10 * 1024 * 1024
    private const val MAX_THUMBNAIL_BYTES = 192 * 1024

    fun read(resolver: ContentResolver, uri: Uri): ByteArray? {
        val retriever = MediaMetadataRetriever()
        val embedded = try {
            resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                retriever.setDataSource(descriptor.fileDescriptor)
                retriever.embeddedPicture
            } ?: return null
        } finally {
            retriever.release()
        }
        if (embedded.isEmpty() || embedded.size > MAX_EMBEDDED_BYTES) return null

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(embedded, 0, embedded.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        // Limit decoded dimensions before allocating pixel storage, including
        // unusually wide/tall artwork. Full-size covers never cross the channel.
        var sampleSize = 1
        val longestEdge = max(bounds.outWidth, bounds.outHeight)
        while (longestEdge / sampleSize > THUMBNAIL_SIZE * 2) sampleSize *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        val decoded = BitmapFactory.decodeByteArray(embedded, 0, embedded.size, options)
            ?: return null
        var thumbnail = decoded
        try {
            val edge = max(decoded.width, decoded.height)
            if (edge > THUMBNAIL_SIZE) {
                val scale = THUMBNAIL_SIZE.toDouble() / edge
                thumbnail = Bitmap.createScaledBitmap(
                    decoded,
                    max(1, (decoded.width * scale).roundToInt()),
                    max(1, (decoded.height * scale).roundToInt()),
                    true,
                )
            }
            val output = ByteArrayOutputStream()
            if (!thumbnail.compress(Bitmap.CompressFormat.JPEG, 85, output)) {
                throw IOException("Unable to encode an artwork thumbnail.")
            }
            return output.toByteArray().takeIf { it.size <= MAX_THUMBNAIL_BYTES }
        } finally {
            if (thumbnail !== decoded) thumbnail.recycle()
            decoded.recycle()
        }
    }
}
