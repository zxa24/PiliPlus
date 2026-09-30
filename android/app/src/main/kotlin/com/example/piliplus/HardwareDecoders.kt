package com.example.piliplus

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build

// LibrePili: which of the codecs bilibili and YouTube serve this device
// decodes in hardware, for marking a quality that would be decoded in
// software (see lib/utils/codec_support.dart, lib/utils/soft_decode.dart).
object HardwareDecoders {
    private val mimeTypes = mapOf(
        "avc" to "video/avc",
        "hevc" to "video/hevc",
        "vp9" to "video/x-vnd.on2.vp9",
        "av1" to "video/av01",
    )

    /** `{"avc": true, "hevc": true, "vp9": false, "av1": false}`. */
    fun query(): Map<String, Boolean> {
        val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder && isHardware(it) }
        return mimeTypes.mapValues { (_, mime) ->
            decoders.any { info ->
                info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }
        }
    }

    private fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return info.isHardwareAccelerated
        }
        // below Android 10 there is no flag, only the naming: the platform's
        // own software codecs are OMX.google.* / c2.android.*, and vendors
        // mark theirs .sw
        val name = info.name.lowercase()
        return !name.startsWith("omx.google.") &&
            !name.startsWith("c2.android.") &&
            !name.contains(".sw.") &&
            !name.endsWith(".sw")
    }
}
