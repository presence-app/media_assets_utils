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

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    applicationContext = flutterPluginBinding.applicationContext
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "media_asset_utils")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    Log.i("MediaAssetsUtils", "onMethodCall: ${call.method} ${call.arguments}")
      when (call.method) {
          "compressVideo" -> {
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
              // Skip files smaller than 5MB
              if (file.length() < 5242880) {
                  Log.i("MediaAssetsUtils - Video Compress", "File size (${file.length()}) < 5MB, returning original")
                  result.success(path)
                  return
              }
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

              Log.i("MediaAssetsUtils - Video Compress", "Input: ${fileSizeInMB}MB, ${width}x${height}, ${bitrate}bps")

              // Skip very small files - already optimized
              if (fileSizeInMB < 5) {
                  Log.i("MediaAssetsUtils - Video Compress", "File < 5MB, returning original")
                  result.success(path)
                  return
              }

              // Calculate output dimensions
              val originalWidth = width
              val originalHeight = height
              val needsResize = width >= quality.value || height >= quality.value

              when {
                  width >= quality.value || height >= quality.value -> {
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

              Log.i("MediaAssetsUtils - Video Compress", "Bitrate calculation: pixels=${outputPixels}, formula=${(outputPixels * 3.5 / 1_000_000)}, calculated=${calculatedBitrate}Mbps")

              // CRITICAL: Intelligent bitrate management
              val sourceBitrateMbps = bitrate / 1_000_000.0  // Keep as double to avoid truncation!
              Log.i("MediaAssetsUtils - Video Compress", "Source bitrate: ${bitrate}bps = ${sourceBitrateMbps}Mbps, needsResize=${needsResize}")

              // Decision logic
              if (sourceBitrateMbps < 2.0) {
                  // Very low source bitrate (< 2 Mbps)
                  if (!needsResize && fileSizeInMB < 20) {
                      // Small file, no resize, low bitrate - skip entirely
                      Log.i("MediaAssetsUtils - Video Compress", "⚠️ SKIPPING: Source ${sourceBitrateMbps}Mbps < 2 Mbps, ${fileSizeInMB}MB file, no resize needed - returning original")
                      mediaMetadataRetriever.release()
                      result.success(path)
                      return
                  } else {
                      // Needs resize or large file - use calculated bitrate (minimum 2 Mbps)
                      Log.i("MediaAssetsUtils - Video Compress", "✓ LOW SOURCE BITRATE: ${sourceBitrateMbps}Mbps, ${originalWidth}x${originalHeight}→${width}x${height}, using calculated ${calculatedBitrate}Mbps")
                  }
              } else if (needsResize) {
                  // Resizing - always use calculated bitrate based on OUTPUT dimensions
                  // Don't cap to source - smaller dimensions need appropriate bitrate
                  Log.i("MediaAssetsUtils - Video Compress", "✓ RESIZING: ${originalWidth}x${originalHeight}→${width}x${height}, source ${sourceBitrateMbps}Mbps, using calculated ${calculatedBitrate}Mbps for output")
              } else {
                  // No resize - cap to source bitrate to avoid making file larger
                  if (calculatedBitrate > sourceBitrateMbps) {
                      val cappedBitrate = Math.round(sourceBitrateMbps).toInt().coerceAtLeast(2)
                      Log.i("MediaAssetsUtils - Video Compress", "⚠️ CAPPING: No resize, calculated (${calculatedBitrate}Mbps) > source (${sourceBitrateMbps}Mbps), using ${cappedBitrate}Mbps")
                      calculatedBitrate = cappedBitrate
                  } else {
                      Log.i("MediaAssetsUtils - Video Compress", "✓ NO RESIZE: Using calculated ${calculatedBitrate}Mbps (source was ${sourceBitrateMbps}Mbps)")
                  }
              }

              Log.i("MediaAssetsUtils - Video Compress", "✅ FINAL: Output ${width}x${height} @ ${calculatedBitrate}Mbps, estimated time: ${(fileSizeInMB * 0.8).toInt()}-${(fileSizeInMB * 1.2).toInt()}s")

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
                          channel.invokeMethod("onVideoCompressProgress", if (percent > 100) { 100 } else { percent})
                      }
                  }

                  override fun onStart(index: Int) {
                      // Compression start
                  }

                  override fun onSuccess(index: Int, size: Long, path: String?) {

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

                          } catch (e: Exception) {
                              Handler(Looper.getMainLooper()).post {
                                  result.error("VideoCompress", e.message, null)
                              }
                          }
                      }
                  }

                  override fun onFailure(index: Int, failureMessage: String) {
                      result.error("MediaAssetsUtils - VideoCompress", failureMessage, null)
                  }

                  override fun onCancelled(index: Int) {
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
