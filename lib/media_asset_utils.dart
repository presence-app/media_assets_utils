import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/log.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/statistics.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

part 'media_info.dart';

enum VideoQuality {
  // 360p
  very_low,
  // 480p
  low,
  // 540p
  medium,
  // 720p
  high,
  // 1080p
  very_high,
}

enum CompressionPlugin {
  ffmpeg,
  lightCompressor,
}

class ThumbnailConfig {
  final int quality;
  final File? file;
  final bool saveToLibrary;
  const ThumbnailConfig({
    this.quality = 100,
    this.saveToLibrary = false,
    this.file,
  });
}

class MediaAssetUtils {
  static MethodChannel _channel = const MethodChannel('media_asset_utils')
    ..setMethodCallHandler(_methodCallHandler);

  static void Function(double)? _onVideoCompressProgress;

  static Future<T?> _invokeMethod<T>(String method, [dynamic arguments]) async {
    try {
      final result = await _channel.invokeMethod(method, arguments);
      return result;
    } on PlatformException {
      rethrow;
    }
  }

  /// Method supports two compression plugin ffmpeg and lightCompressor
  /// ffmpeg is the default one because lightCompressor corrupt files in a way
  /// that they are not played quickly on android.
  /// [saveToLibrary] can be used only if [CompressionPlugin.lightCompressor]
  static Future<File?> compressVideo(
    File file, {
    String? videoName,
    int? customBitRate = 5,
    CompressionPlugin? compressionPlugin = CompressionPlugin.ffmpeg,
    bool saveToLibrary = false,
    VideoQuality quality = VideoQuality.very_low,
    void Function(double)? onVideoCompressProgress,
    ThumbnailConfig? thumbnailConfig,
  }) async {
    try {
      var startTime = DateTime.timestamp();
      final directory = await getApplicationCacheDirectory();
      final dirPath = directory.path;
      String? outputPath = '${dirPath}/${basename(file.path)}';

      if (compressionPlugin == CompressionPlugin.ffmpeg) {
        print("outputPath ${outputPath}");
        final videoDuration = (await getVideoInfo(file)).duration!;
        print("duration ${videoDuration}");

        // COMPRESS WITH FFMPEG
        // This track execution time or other properties from session
        FFmpegKitConfig.enableStatisticsCallback((statistics) {
          // debugPrint('Time ${statistics.getTime()}');
        });

        final crfValue = quality == VideoQuality.very_high
            ? 23
            : quality == VideoQuality.high
            ? 28
            : 33;

        final presetValue = quality == VideoQuality.very_high
            ? 'fast'
            : quality == VideoQuality.high
            ? 'ultrafast'
            : 'veryfast';

        // THEORY
        //  String command = "-i $filePath -c:v libx264 -crf 23 -preset veryfast -g 15 -r 25 -y $compressedFilePath";
        // -crf is constant rate factor. The higher the more compression and worst quality.
        // Usually set to 22 or 23, common range is [17-28].
        // -r is fps. If set to 25 it will change original one and compress a
        // -s size (ie. -s 640x360). If left out it will use original one
        // -g is keyframe interval. The higher the more compression. If video will be cut it is best to set it to 0 (no more than 12,
        // -y to overwrite output file if already exists
        // usually half value of the fps)
        // if video won't be cut, it can be set to 250
        // audio can be not manipulated coz it doesnt address much on size
        //  -c:a aac -b:a 128k -ac 2 -ar 44100
        // -tune zerolatency good for fast encoding and low-latency streaming; -tune fastdecode is for faster decode
        // preset veryfast, superfast and ultrafast
        // https://stackoverflow.com/a/76785827
        // https://stackoverflow.com/questions/64999614/are-there-any-side-effect-of-using-preset-ultrafast-in-ffmpeg-command
        // presets available: https://superuser.com/questions/1556953/why-does-preset-veryfast-in-ffmpeg-generate-the-most-compressed-file-compared
        // NOTE: Using ultrafast preset without -g 15 provides good result with fast decoding
        // String command = "-i ${filePath} -c:v libx264 -crf 26 -tune fastdecode -preset ultrafast -r 25 -y ${compressedFilePath}";
        // We can also remove -r 25
        // String command = "-i ${filePath} -c:v libx264 -crf 26 -tune fastdecode -preset ultrafast -y ${compressedFilePath}";
        String command = "-i ${file.path} -c:v libx264 -crf $crfValue -tune fastdecode -preset $presetValue -y $outputPath";

        FFmpegKit.executeAsync(command, (session) async {
          final returnCode = await session.getReturnCode();
          // Print error stack
          final failStackTrace = await session.getFailStackTrace();

          if (ReturnCode.isSuccess(returnCode)){
            //print('Compress success');
            print('Time elapsed for compressing file with FFmpeg '
                '${DateTime.timestamp().difference(startTime).inMilliseconds}ms');
            print("Video Compression: initial File size: ${file.lengthSync()}");
            print("Video Compression: compressed File size: ${File(outputPath).lengthSync()}");
            //SUCCESS
          } else if (ReturnCode.isCancel(returnCode)) {
            print("Video Compression: compress cancelled");
            // CANCEL
          } else {
            print('Video Compression: compress error');
            print('Video Compression: failStackTrace $failStackTrace');
            final logs = await session.getLogs();
            print('Video Compression: last log message ${logs.last.getMessage()}');
            FFmpegKitConfig.enableLogCallback((log) {
              final message = log.getMessage();
              print('Video Compression: log message: $message');
            });
            // ERROR
          }
        },
        // ON PROGRESS - via Log / Statistics
        (Log log) {},
        (Statistics statistics) {
          if (statistics.getTime() > 0) {
               dynamic progress = ((statistics.getTime() * 100) / videoDuration).ceil();
               _onVideoCompressProgress?.call(progress);
               print('Video Compression: progress $progress');
          }
        });
      }
      else {
        final str = quality.toString();
        final qstr = str.substring(str.indexOf('.') + 1);
        _onVideoCompressProgress = onVideoCompressProgress;
        final String? outputPath = await _invokeMethod('compressVideo', {
          'path': file.path,
          'videoName': videoName,
          'saveToLibrary': saveToLibrary,
          'quality': qstr.toUpperCase(),
          'customBitrate': customBitRate,
          'storeThumbnail': thumbnailConfig != null,
          'thumbnailSaveToLibrary': thumbnailConfig?.saveToLibrary ?? false,
          'thumbnailPath': thumbnailConfig?.file?.path,
          'thumbnailQuality': thumbnailConfig?.quality ?? 100,
        });
        print('Time elapsed for compressing file with lightCompressor '
            '${DateTime.timestamp().difference(startTime).inMilliseconds}ms');
        print("Compression: initial File size: ${file.lengthSync()}");
        if (outputPath != null) print("Compression: compressed File size: ${File(outputPath).lengthSync()}");
        _onVideoCompressProgress = null;
        return outputPath == null ? null : File(outputPath);
      }
      return File(outputPath).existsSync()
          && File(outputPath).lengthSync() > 0 ? File(outputPath) : null;
    } on PlatformException {
      _onVideoCompressProgress = null;
      rethrow;
    }

  }

  static Future<File?> compressImage(
    File file, {
    File? outputFile,
    bool saveToLibrary = false,
  }) async {
    final String? result = await _invokeMethod('compressImage', {
      'path': file.path,
      'outputPath': outputFile?.path,
      'saveToLibrary': saveToLibrary,
    });
    return result == null ? null : File(result);
  }

  static Future<File?> getVideoThumbnail(
    File file, {
    File? thumbnailFile,
    int quality = 100,
    bool saveToLibrary = false,
  }) async {
    assert(100 >= quality, 'quality cannot be greater than 100');
    final String? result = await _invokeMethod('getVideoThumbnail', {
      'path': file.path,
      'thumbnailPath': thumbnailFile?.path,
      'quality': quality,
      'saveToLibrary': saveToLibrary,
    });
    return result == null ? null : File(result);
  }

  static Future<bool?> saveToGallery<T>(T data) async {
    assert(data is File || data is Uint8List,
        'data can only be File and Uint8List');
    bool? result;
    if (data is File) {
      result = await _invokeMethod('saveFileToGallery', {
        'path': data.path,
      });
    } else {
      // result = await _invokeMethod('saveImageToGallery', {
      //   'data': data,
      // });
      throw UnimplementedError();
    }
    return result;
  }

  static Future<VideoInfo> getVideoInfo(
    File file,
  ) async {
    final json = await _invokeMethod('getVideoInfo', {
      'path': file.path,
    });
    return VideoInfo.fromJson(json);
  }

  static Future<ImageInfo> getImageInfo(
    File file,
  ) async {
    final json = await _invokeMethod('getImageInfo', {
      'path': file.path,
    });
    return ImageInfo.fromJson(json);
  }

  static Future<void> _methodCallHandler(MethodCall call) {
    //print(
    //  "MediaAssetsUtils:onMethodCall(method: ${call.method}, arguments: ${call.arguments})",);
    final args = call.arguments;
    switch (call.method) {
      case 'onVideoCompressProgress':
        _onVideoCompressProgress?.call(args);
        break;
      default:
    }
    return Future.value();
  }
}
