package com.lucky1213.media_asset_utils

import android.content.Context
import android.graphics.Bitmap
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.*
import android.text.TextUtils
import android.util.Log
import com.abedelazizshe.lightcompressorlibrary.CompressionListener
import com.abedelazizshe.lightcompressorlibrary.VideoCompressor
import com.abedelazizshe.lightcompressorlibrary.VideoQuality
import com.abedelazizshe.lightcompressorlibrary.config.AppSpecificStorageConfiguration
import com.abedelazizshe.lightcompressorlibrary.config.Configuration
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject
import top.zibin.luban.Luban
import top.zibin.luban.OnCompressListener
import java.io.*
import kotlin.concurrent.thread
import kotlin.math.ceil


enum class DirectoryType(val value: String) {
    MOVIES(Environment.DIRECTORY_MOVIES),
    PICTURES(Environment.DIRECTORY_PICTURES),
    MUSIC(Environment.DIRECTORY_MUSIC),
    DCIM(Environment.DIRECTORY_DCIM),
    DOCUMENTS(Environment.DIRECTORY_DOCUMENTS),
    DOWNLOADS(Environment.DIRECTORY_DOWNLOADS)
}

enum class VideoOutputQuality(val value:Int, val level: VideoQuality){
    VERY_LOW(640, VideoQuality.VERY_LOW),
    LOW(640, VideoQuality.LOW),
    MEDIUM(960, VideoQuality.MEDIUM),
    HIGH(1280, VideoQuality.HIGH),
    VERY_HIGH(1920, VideoQuality.VERY_HIGH)
}


/** MediaAssetsUtilsPlugin */
class MediaAssetsUtilsPlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel
  private lateinit var applicationContext : Context
  
  // Track multiple concurrent compressions
  private val activeCompressions = mutableMapOf<String, Boolean>() // compressionId -> isCancelled

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    applicationContext = flutterPluginBinding.applicationContext
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "media_asset_utils")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    Log.i("MediaAssetsUtils", "onMethodCall: ${call.method} ${call.arguments}")
      when (call.method) {
          "compressVideo" -> {
              val compressionId = call.argument<String>("compressionId") ?: return
              
              // Register this compression as active
              activeCompressions[compressionId] = false
              
              val path = call.argument<String>("path")!!
              val customBitRate = call.argument<Int>("customBitRate") ?: 5
              val quality = VideoOutputQuality.valueOf(call.argument<String>("quality")?.uppercase() ?: "MEDIUM")
              Log.i("MediaAssetsUtils - Video Compress", "🔧 Parameters: customBitRate=${customBitRate}Mbps, quality=${quality.name}")
              val tempPath = call.argument<String>("outputPath")
              val outputPath = tempPath ?: MediaStoreUtils.generateTempPath(applicationContext, DirectoryType.MOVIES.value, ".mp4")
              val outFile = File(outputPath)
              val file = File(path)

              val saveToLibrary = call.argument<Boolean>("saveToLibrary") ?: false
              val storeThumbnail = call.argument<Boolean>("storeThumbnail") ?: true
              val thumbnailSaveToLibrary = call.argument<Boolean>("thumbnailSaveToLibrary") ?: false
              val thumbnailPath = call.argument<String>("thumbnailPath")
              val thumbnailQuality = call.argument<Int>("thumbnailQuality") ?: 100
              
              val mediaMetadataRetriever = MediaMetadataRetriever()
              try {
                  mediaMetadataRetriever.setDataSource(path)
              } catch (e: IllegalArgumentException) {
                  result.error("MediaAssetsUtils - VideoCompress", e.message, null)
                  return
              }

              val bitrate = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toInt()
              var width = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt()
              var height = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt()
              if (bitrate == null || width == null || height == null) {
                  result.error("MediaAssetsUtils - VideoCompress", "Cannot find video track.", null)
                  return
              }

              val fileSize = file.length()
              val fileSizeInMB = fileSize / 1048576.0

              Log.i("MediaAssetsUtils - Video Compress", " INPUT FILE INFO:")
              Log.i("MediaAssetsUtils - Video Compress", "  Size: ${fileSizeInMB.toInt()}MB (${fileSizeInMB}MB)")
              Log.i("MediaAssetsUtils - Video Compress", "  Dimensions: ${width}x${height}")
              Log.i("MediaAssetsUtils - Video Compress", "  Bitrate: ${bitrate}bps")
              Log.i("MediaAssetsUtils - Video Compress", "  Target Quality: ${quality.name} (max side: ${quality.value}px)")
              Log.i("MediaAssetsUtils - Video Compress", "  Custom Bitrate Cap: ${customBitRate}Mbps")

              // Check file extension - always compress if not MP4 compatible format
              val fileExtension = file.extension.lowercase()
              val mp4CompatibleFormats = setOf("mp4", "m4v")
              val isMP4Compatible = fileExtension in mp4CompatibleFormats
              
              if (!isMP4Compatible) {
                  Log.i("MediaAssetsUtils - Video Compress", "")
                  Log.i("MediaAssetsUtils - Video Compress", "FILE FORMAT CHECK:")
                  Log.i("MediaAssetsUtils - Video Compress", "  Current format: .${fileExtension} (not MP4 compatible)")
                  Log.i("MediaAssetsUtils - Video Compress", "  Compatible formats: ${mp4CompatibleFormats.joinToString(", ") { ".$it" }}")
                  Log.i("MediaAssetsUtils - Video Compress", "")
                  Log.i("MediaAssetsUtils - Video Compress", "DECISION: COMPRESS (format conversion)")
                  Log.i("MediaAssetsUtils - Video Compress", "  Reason: Video must be converted to MP4 for player compatibility")
                  Log.i("MediaAssetsUtils - Video Compress", "  → Will output as MP4 format")
              } else {
                  Log.i("MediaAssetsUtils - Video Compress", "")
                  Log.i("MediaAssetsUtils - Video Compress", "FILE FORMAT CHECK:")
                  Log.i("MediaAssetsUtils - Video Compress", "  Current format: .${fileExtension} (MP4 compatible ✓)")
                  
                  // Skip very small MP4-compatible files - already optimized
                  if (fileSizeInMB < 7) {
                      Log.i("MediaAssetsUtils - Video Compress", "SKIP: File size ${fileSizeInMB.toInt()}MB < 7MB threshold (MP4-compatible) - returning original")
                      result.success(path)
                      return
                  }
              }

              // Calculate output dimensions
              val originalWidth = width
              val originalHeight = height
              val needsResize = width > quality.value || height > quality.value

              when {
                  width > quality.value || height > quality.value -> {
                      when {
                          width > height -> {
                              height = ceil(height * quality.value / width.toDouble()).toInt()
                              width = quality.value
                          }
                          height > width -> {
                              width = ceil(width * quality.value / height.toDouble()).toInt()
                              height = quality.value
                          }
                          else -> {
                              width = quality.value
                              height = quality.value
                          }
                      }
                  }
              }

              // Calculate safe bitrate based on OUTPUT dimensions
              // Formula: (pixels × 3.5) / 1M for better quality (was 2.1, too aggressive)
              // This gives: 720p=3.2Mbps, 1080p=7.2Mbps (but capped at customBitRate default 5Mbps)
              val outputPixels = width * height
              var calculatedBitrate = Math.round((outputPixels * 3.5) / 1_000_000).toInt().coerceIn(2, customBitRate)

              Log.i("MediaAssetsUtils - Video Compress", "BITRATE CALCULATION:")
              Log.i("MediaAssetsUtils - Video Compress", "  Output size: ${width}x${height} (${outputPixels} pixels)")
              Log.i("MediaAssetsUtils - Video Compress", "  Formula: (${outputPixels} × 3.5) / 1,000,000 = ${(outputPixels * 3.5 / 1_000_000).toInt()}Mbps")
              Log.i("MediaAssetsUtils - Video Compress", "  Calculated bitrate: ${calculatedBitrate}Mbps (capped to custom: ${customBitRate}Mbps)")

              // CRITICAL: Intelligent bitrate management
              val sourceBitrateMbps = bitrate / 1_000_000.0  // Keep as double to avoid truncation!
              Log.i("MediaAssetsUtils - Video Compress", "")
              Log.i("MediaAssetsUtils - Video Compress", "COMPRESSION DECISION LOGIC:")
              Log.i("MediaAssetsUtils - Video Compress", "  Source bitrate: ${String.format("%.2f", sourceBitrateMbps)}Mbps")
              Log.i("MediaAssetsUtils - Video Compress", "  Resize needed: $needsResize (current ${originalWidth}x${originalHeight} vs quality max ${quality.value}px)")
              Log.i("MediaAssetsUtils - Video Compress", "  File size: ${fileSizeInMB.toInt()}MB")

              // Decision logic: Compress only if bitrate is HIGH (file is large/heavy)
              if (!isMP4Compatible) {
                  // Non-MP4 format - always compress for format conversion
                  // Continue to compression (don't return early)
              } else if (sourceBitrateMbps < 2.0 && !needsResize) {
                  // Very low source bitrate AND no resize needed - skip compression
                  // File is already optimized, no point compressing further
                  Log.i("MediaAssetsUtils - Video Compress", "")
                  Log.i("MediaAssetsUtils - Video Compress", "❌ DECISION: SKIP COMPRESSION")
                  Log.i("MediaAssetsUtils - Video Compress", "  Reasons:")
                  Log.i("MediaAssetsUtils - Video Compress", "    • Source bitrate is very low: ${String.format("%.2f", sourceBitrateMbps)}Mbps < 2Mbps")
                  Log.i("MediaAssetsUtils - Video Compress", "    • No resize needed: ${originalWidth}x${originalHeight} fits quality limit")
                  Log.i("MediaAssetsUtils - Video Compress", "  → File already optimized, returning original")
                  mediaMetadataRetriever.release()
                  result.success(path)
                  return
              } else if (needsResize) {
                  // Resize required - but only compress if bitrate is HIGH enough to justify re-encoding
                  // Low bitrate files are already optimized; re-encoding will enlarge them
                  if (sourceBitrateMbps < 2.0) {
                      // Low bitrate + needs resize = file already optimized, skip re-encoding
                      Log.i("MediaAssetsUtils - Video Compress", "")
                      Log.i("MediaAssetsUtils - Video Compress", "❌ DECISION: SKIP COMPRESSION")
                      Log.i("MediaAssetsUtils - Video Compress", "  Reasons:")
                      Log.i("MediaAssetsUtils - Video Compress", "    • Resize needed: ${originalWidth}x${originalHeight} exceeds ${quality.value}px limit")
                      Log.i("MediaAssetsUtils - Video Compress", "    • BUT source bitrate is very low: ${String.format("%.2f", sourceBitrateMbps)}Mbps")
                      Log.i("MediaAssetsUtils - Video Compress", "    • Re-encoding will enlarge file (overhead > size reduction)")
                      Log.i("MediaAssetsUtils - Video Compress", "  → Returning original file (size: ${fileSizeInMB.toInt()}MB)")
                      mediaMetadataRetriever.release()
                      result.success(path)
                      return
                  } else {
                      // High bitrate + needs resize = compress with calculated bitrate
                      Log.i("MediaAssetsUtils - Video Compress", "")
                      Log.i("MediaAssetsUtils - Video Compress", "✅ DECISION: COMPRESS (resize required)")
                      Log.i("MediaAssetsUtils - Video Compress", "  Reasons:")
                      Log.i("MediaAssetsUtils - Video Compress", "    • Resize needed: ${originalWidth}x${originalHeight} exceeds ${quality.value}px limit")
                      Log.i("MediaAssetsUtils - Video Compress", "    • Target dimensions: ${width}x${height}")
                      Log.i("MediaAssetsUtils - Video Compress", "    • Source bitrate is moderate/high: ${String.format("%.2f", sourceBitrateMbps)}Mbps")
                      Log.i("MediaAssetsUtils - Video Compress", "  → Using calculated bitrate for output: ${calculatedBitrate}Mbps")
                  }
              } else if (sourceBitrateMbps >= 5.0) {
                  // HIGH bitrate - compress to optimize file size
                  Log.i("MediaAssetsUtils - Video Compress", "")
                  Log.i("MediaAssetsUtils - Video Compress", "✅ DECISION: COMPRESS (high bitrate)")
                  Log.i("MediaAssetsUtils - Video Compress", "  Reasons:")
                  Log.i("MediaAssetsUtils - Video Compress", "    • Source bitrate is high: ${String.format("%.2f", sourceBitrateMbps)}Mbps >= 5Mbps threshold")
                  Log.i("MediaAssetsUtils - Video Compress", "    • File is large: ${fileSizeInMB.toInt()}MB")
                  Log.i("MediaAssetsUtils - Video Compress", "  → Using calculated bitrate: ${calculatedBitrate}Mbps (will reduce file size)")
              } else {
                  // Moderate bitrate (2-5 Mbps) - skip, file is already reasonably optimized
                  Log.i("MediaAssetsUtils - Video Compress", "")
                  Log.i("MediaAssetsUtils - Video Compress", "❌ DECISION: SKIP COMPRESSION")
                  Log.i("MediaAssetsUtils - Video Compress", "  Reasons:")
                  Log.i("MediaAssetsUtils - Video Compress", "    • Source bitrate is moderate: ${String.format("%.2f", sourceBitrateMbps)}Mbps (2-5 range)")
                  Log.i("MediaAssetsUtils - Video Compress", "    • File is already reasonably optimized, no resize needed")
                  Log.i("MediaAssetsUtils - Video Compress", "  → Returning original file")
                  mediaMetadataRetriever.release()
                  result.success(path)
                  return
              }

              Log.i("MediaAssetsUtils - Video Compress", "")
              Log.i("MediaAssetsUtils - Video Compress", "COMPRESSION PARAMETERS:")
              Log.i("MediaAssetsUtils - Video Compress", "  Output: ${width}x${height}px @ ${calculatedBitrate}Mbps")
              Log.i("MediaAssetsUtils - Video Compress", "  Estimated duration: ~${(fileSizeInMB * 0.8).toInt()}-${(fileSizeInMB * 1.2).toInt()}s")
              Log.i("MediaAssetsUtils - Video Compress", "")

              mediaMetadataRetriever.release()

              if (!outFile.parentFile!!.exists()) {
                  outFile.parentFile!!.mkdirs()
              }

              Log.i("MediaAssetsUtils - outFile", outFile.path)
              VideoCompressor.start(
                  context = applicationContext, // => This is required
                  uris =  listOf(Uri.fromFile(file)),
                  isStreamable = false,

                  storageConfiguration = AppSpecificStorageConfiguration(
                      //  videoName = outFile.nameWithoutExtension,
                      // subFolderName = DirectoryType.MOVIES.value,
                  ),
                  configureWith = Configuration(
                      quality = quality.level,
                      isMinBitrateCheckEnabled = false, // Disable library check - we handle bitrate ourselves
                      keepOriginalResolution = false,
                      videoWidth = width.toDouble(),
                      videoHeight = height.toDouble(),
                      videoNames = listOf(outFile.nameWithoutExtension),
                      // Use our calculated safe bitrate based on output dimensions
                      videoBitrateInMbps = calculatedBitrate
                    ),
                listener = object : CompressionListener {
                  override fun onProgress(index: Int, percent: Float) {
                      // Update UI with progress value
                      Handler(Looper.getMainLooper()).post {
                          Log.i("MediaAssetsUtils - onVideoCompressProgress", percent.toString())
                          channel.invokeMethod("onVideoCompressProgress", mapOf(
                              "compressionId" to compressionId,
                              "progress" to (if (percent > 100) 100 else percent)
                          ))
                      }
                  }

                  override fun onStart(index: Int) {
                      // Compression start
                  }

                  override fun onSuccess(index: Int, size: Long, path: String?) {
                      // Check if cancellation was requested before continuing
                      if (activeCompressions[compressionId] == true) {
                          Handler(Looper.getMainLooper()).post {
                              result.error("MediaAssetsUtils - VideoCompress", "The transcoding operation was canceled.", null)
                          }
                          activeCompressions.remove(compressionId)
                          return
                      }

                      thread {
                          try {
                              val tempFile = File(path!!)
                              copyFile(tempFile, outFile)

                              // Calculate compression statistics
                              val inputSizeMB = file.length() / 1048576.0
                              val outputSizeMB = outFile.length() / 1048576.0
                              val reduction = ((inputSizeMB - outputSizeMB) / inputSizeMB * 100)
                              val compressionTime = (System.currentTimeMillis() - 0) / 1000.0 // Approximate

                              // Log comprehensive summary
                              Log.i("MediaAssetsUtils - COMPRESSION SUMMARY", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                              Log.i("MediaAssetsUtils - COMPRESSION SUMMARY", "Input:  ${inputSizeMB.toInt()}MB @ ${bitrate}bps (${originalWidth}x${originalHeight})")
                              Log.i("MediaAssetsUtils - COMPRESSION SUMMARY", "Output: ${outputSizeMB.toInt()}MB @ ${calculatedBitrate}Mbps (${width}x${height})")
                              Log.i("MediaAssetsUtils - COMPRESSION SUMMARY", "Reduction: ${reduction.toInt()}% (saved ${(inputSizeMB - outputSizeMB).toInt()}MB)")
                              Log.i("MediaAssetsUtils - COMPRESSION SUMMARY", "Quality: ${quality.name}, Bitrate formula: 3.5x")
                              Log.i("MediaAssetsUtils - COMPRESSION SUMMARY", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

                              if (storeThumbnail) {
                                  storeThumbnailToFile(outputPath, thumbnailPath, thumbnailQuality, thumbnailSaveToLibrary)
                              }
                              Handler(Looper.getMainLooper()).post {
                                  result.success(outputPath)
                              }
                              if (saveToLibrary) {
                                  MediaStoreUtils.insert(applicationContext, outFile)
                              }
                              activeCompressions.remove(compressionId)

                          } catch (e: Exception) {
                              Handler(Looper.getMainLooper()).post {
                                  result.error("VideoCompress", e.message, null)
                              }
                              activeCompressions.remove(compressionId)
                          }
                      }
                  }

                  override fun onFailure(index: Int, failureMessage: String) {
                      activeCompressions.remove(compressionId)
                      result.error("MediaAssetsUtils - VideoCompress", failureMessage, null)
                  }

                  override fun onCancelled(index: Int) {
                      // Clean up temporary files on cancellation
                      if (outFile.exists()) {
                          try {
                              outFile.delete()
                              Log.i("MediaAssetsUtils - VideoCompress", "Cleaned up temporary file: ${outFile.path}")
                          } catch (e: Exception) {
                              Log.e("MediaAssetsUtils - VideoCompress", "Failed to delete temporary file: ${e.message}")
                          }
                      }
                      activeCompressions.remove(compressionId)
                      Handler(Looper.getMainLooper()).post {
                          result.error("MediaAssetsUtils - VideoCompress", "The transcoding operation was canceled.", null)
                      }
                  }

                },

              )
          }
          "compressImage" -> {
              val path = call.argument<String>("path")!!
              val srcFile = File(path)
              val tempPath = call.argument<String>("outputPath")
              val outputPath = tempPath ?: MediaStoreUtils.generateTempPath(applicationContext, DirectoryType.PICTURES.value, ".${srcFile.extension}")
              val outputFile = File(outputPath)
              val saveToLibrary = call.argument<Boolean>("saveToLibrary") ?: false
              if (!outputFile.parentFile!!.exists()) {
                  outputFile.parentFile!!.mkdirs()
              }
              Luban.with(applicationContext)
                      .load(srcFile)
                      .ignoreBy(0)
                      .setTargetDir(outputFile.parent)
                      .setFocusAlpha(outputFile.extension == "png")
                      .filter { path -> !(TextUtils.isEmpty(path) || path.lowercase().endsWith(".gif")) }
                      .setCompressListener(object : OnCompressListener {
                          override fun onStart() {
                              Log.i("ImageCompress", "onStart")
                          }

                          override fun onSuccess(file: File) {
                              result.success(file.absolutePath)
                              if (saveToLibrary && file.absolutePath == outputFile.absolutePath) {
                                  MediaStoreUtils.insert(applicationContext, file)
                              }
                          }

                          override fun onError(e: Throwable) {
                              result.error("ImageCompress", e.message, e.stackTrace)
                          }
                      })
                      .setRenameListener {
                          outputFile.name
                      }
                      .launch()
          }
          "getVideoInfo" -> {
              val path = call.argument<String>("path")!!
              val file = File(path)
              val mediaMetadataRetriever =  MediaMetadataRetriever()
              mediaMetadataRetriever.setDataSource(path)
              val durationStr = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
              val title = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE) ?: ""
              val author = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_AUTHOR) ?: ""
              val widthStr = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
              val heightStr = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
              val duration = durationStr?.toInt()
              var width = widthStr?.toInt()
              var height = heightStr?.toInt()
              val filesize = file.length()
              val rotation = mediaMetadataRetriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)

              mediaMetadataRetriever.release()

              val ori = rotation?.toIntOrNull()
              if (ori != null) {
                  if (ori == 90 || ori == 270) {
                      val tmp = width
                      width = height
                      height = tmp
                  }
              }
              val json = JSONObject()

              json.put("path", path)
              json.put("title", title)
              json.put("author", author)
              json.put("width", width)
              json.put("height", height)
              json.put("duration", duration)
              json.put("filesize", filesize)
              json.put("rotation", ori)
              result.success(json.toString())
          }
          "getImageInfo" -> {
              val path = call.argument<String>("path")!!
              val file = File(path)
              val exifInterface = ExifInterface(file.absolutePath)
              val filesize = file.length()
              var width: Int?
              var height: Int?
              val orientation: Int?
              try {
                  width = exifInterface.getAttributeInt(ExifInterface.TAG_IMAGE_WIDTH, 0)
                  height = exifInterface.getAttributeInt(ExifInterface.TAG_IMAGE_LENGTH, 0)
                  orientation = exifInterface.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)

                  if (orientation == ExifInterface.ORIENTATION_TRANSPOSE || orientation == ExifInterface.ORIENTATION_ROTATE_90 || orientation == ExifInterface.ORIENTATION_TRANSVERSE || orientation == ExifInterface.ORIENTATION_ROTATE_270) {
                      val temp = width
                      width = height
                      height = temp
                  }
                  val json = JSONObject()

                  json.put("path", path)
                  json.put("width", width)
                  json.put("height", height)
                  json.put("orientation", orientation)
                  json.put("filesize", filesize)

                  result.success(json.toString())
              } catch (e: IOException) {
                  result.error("getImageInfo", e.message, null)
              }
          }
          "getVideoThumbnail" -> {
              val path = call.argument<String>("path")!!
              val thumbnailPath = call.argument<String>("thumbnailPath")
              val quality = call.argument<Int>("quality") ?: 100
              val saveToLibrary = call.argument<Boolean>("saveToLibrary") ?: false
              try {
                  result.success(storeThumbnailToFile(path, thumbnailPath, quality, saveToLibrary))
              } catch (e: Exception) {
                  result.error("VideoThumbnail", e.message, null)
              }
          }
          "saveFileToGallery" -> {
              val path = call.argument<String>("path") ?: return
              thread {
                  try {
                      val srcFile = File(path)
                      MediaStoreUtils.insert(applicationContext, srcFile)
                      Handler(Looper.getMainLooper()).post {
                          result.success(true)
                      }
                  } catch (e: Exception) {
                      Handler(Looper.getMainLooper()).post {
                          result.error("SaveToGallery", e.message, null)
                      }
                  }
              }
          }
          "cancelVideoCompression" -> {
              val compressionId = call.argument<String>("compressionId") ?: return
              if (activeCompressions.containsKey(compressionId)) {
                  // Mark this compression as cancelled
                  activeCompressions[compressionId] = true
                  // Cancel all ongoing compressions via VideoCompressor
                  VideoCompressor.cancel()
                  result.success(true)
              } else {
                  result.success(false)
              }
          }
          // "saveImageToGallery" -> {
          //     val data = call.argument<String>("data") ?: return
          //     thread {
          //         try {
          //           val srcFile = File(MediaStoreUtils.generateTempPath(applicationContext, DirectoryType.PICTURES.value, extension = ".jpg"))
          //           val fos = FileOutputStream(srcFile)
          //           val bmp = BitmapFactory.decodeByteArray(data, 0, data.size)
          //           bmp.compress(Bitmap.CompressFormat.JPEG, quality, fos)
          //           fos.flush()
          //           fos.close()
          //           MediaStoreUtils.insert(applicationContext, srcFile)
          //           bmp.recycle()
          //           Handler(Looper.getMainLooper()).post {
          //               result.success(true)
          //           }
          //         } catch (e: Exception) {
          //             Handler(Looper.getMainLooper()).post {
          //                 result.error("SaveToGallery", e.message, null)
          //             }
          //         }
          //     }
          // }
          else -> {
              result.error("NoImplemented", "Handles a call to an unimplemented method.", null)
          }
      }
  }

    private fun storeThumbnailToFile(path: String, thumbnailPath: String? = null, quality: Int = 100, saveToLibrary: Boolean = true) : String? {
        val mediaMetadataRetriever = MediaMetadataRetriever()
        try {
            mediaMetadataRetriever.setDataSource(File(path).absolutePath)
        } catch (e: IllegalArgumentException){
            throw e
        }
        val bitmap: Bitmap? = mediaMetadataRetriever.getFrameAtTime(0 * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
        mediaMetadataRetriever.release()
        var format = Bitmap.CompressFormat.JPEG
        if (thumbnailPath != null) {
            val outputDir = File(thumbnailPath).parentFile!!
            if (!outputDir.exists()) {
                outputDir.mkdirs()
            }
            val extension = MediaStoreUtils.getFileExtension(thumbnailPath)
            format = when (extension) {
                "jpg", "jpeg" -> {
                    Bitmap.CompressFormat.JPEG
                }
                "png" -> {
                    Bitmap.CompressFormat.PNG
                }
                else -> {
                    Bitmap.CompressFormat.JPEG
                }
            }
        }

        val file = if (thumbnailPath != null) {
            File(thumbnailPath)
        } else {
            File(MediaStoreUtils.generateTempPath(applicationContext, DirectoryType.MOVIES.value, extension = ".jpg", filename = File(path).nameWithoutExtension+"_thumbnail"))
        }
        if (file.exists()) {
            file.delete()
        }
        try {
            //outputStream获取文件的输出流对象
            val fos: OutputStream = file.outputStream()
            //压缩格式为JPEG图像，压缩质量为100%
            bitmap!!.compress(format, quality, fos)
            fos.flush()
            fos.close()
            if (saveToLibrary) {
                MediaStoreUtils.insert(applicationContext, file)
            }
            return file.absolutePath
        } catch (e: Exception) {
            throw RuntimeException(e)
        }
    }


    private fun copyFile(src: File, dest: File) {
        FileInputStream(src).channel.use { sourceChannel ->
            FileOutputStream(dest).channel
                .use { destChannel -> destChannel.transferFrom(sourceChannel, 0, sourceChannel.size()) }
        }
    }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
