import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

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

  // Track progress callbacks for each compression by ID
  static final Map<String, void Function(double)> _progressCallbacks = {};

  // Track all active compression IDs
  static final Set<String> _activeCompressions = {};

  // Track the last compression ID for easy access
  static String? _lastCompressionId;

  static Future<T?> _invokeMethod<T>(String method, [dynamic arguments]) async {
    try {
      final result = await _channel.invokeMethod(method, arguments);
      return result;
    } on PlatformException {
      rethrow;
    }
  }

  /// Method supports two compression plugin lightCompressor
  /// Returns a compression ID that can be used to cancel this specific compression
  static Future<File?> compressVideo(
    File file, {
    String? videoName,
    int? customBitRate = 5,
    bool saveToLibrary = false,
    VideoQuality quality = VideoQuality.very_low,
    void Function(double)? onVideoCompressProgress,
    void Function(String)? onCompressionIdGenerated,
    ThumbnailConfig? thumbnailConfig,
  }) async {
    try {
      var startTime = DateTime.timestamp();

      final str = quality.toString();
      final qstr = str.substring(str.indexOf('.') + 1);

      // Generate a unique compression ID for this operation
      final compressionId = DateTime.now().millisecondsSinceEpoch.toString() +
          '_${Random().nextInt(100000)}';

      // Store this as the last compression ID and notify caller
      _lastCompressionId = compressionId;
      onCompressionIdGenerated?.call(compressionId);

      // Store progress callback for this compression
      if (onVideoCompressProgress != null) {
        _progressCallbacks[compressionId] = onVideoCompressProgress;
      }
      _activeCompressions.add(compressionId);

      try {
        final String? outputPath = await _invokeMethod('compressVideo', {
          'path': file.path,
          'videoName': videoName,
          'saveToLibrary': saveToLibrary,
          'quality': qstr.toUpperCase(),
          'customBitRate': customBitRate,
          'storeThumbnail': thumbnailConfig != null,
          'thumbnailSaveToLibrary': thumbnailConfig?.saveToLibrary ?? false,
          'thumbnailPath': thumbnailConfig?.file?.path,
          'thumbnailQuality': thumbnailConfig?.quality ?? 100,
          'compressionId': compressionId,
        });
        print('Time elapsed for compressing file with lightCompressor '
            '${DateTime.timestamp().difference(startTime).inMilliseconds}ms');
        print("Compression: initial File size: ${file.lengthSync()}");
        if (outputPath != null)
          print(
              "Compression: compressed File size: ${File(outputPath).lengthSync()}");

        // Clean up this compression's resources
        _progressCallbacks.remove(compressionId);
        _activeCompressions.remove(compressionId);

        return outputPath == null ? null : File(outputPath);
      } catch (e) {
        // Clean up on error
        _progressCallbacks.remove(compressionId);
        _activeCompressions.remove(compressionId);
        rethrow;
      }
    } on PlatformException {
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
    final args = call.arguments;
    switch (call.method) {
      case 'onVideoCompressProgress':
        // args contains {compressionId: String, progress: double}
        if (args is Map) {
          final compressionId = args['compressionId'] as String?;
          final progress = args['progress'] as double?;

          if (compressionId != null && progress != null) {
            final callback = _progressCallbacks[compressionId];
            callback?.call(progress);
          }
        }
        break;
      default:
    }
    return Future.value();
  }

  /// Cancel a specific video compression by its compression ID
  /// Returns true if cancellation was successful, false if compression ID not found
  static Future<bool> cancelVideoCompression(String compressionId) async {
    if (!_activeCompressions.contains(compressionId)) {
      return false;
    }

    try {
      final result = await _invokeMethod<bool>('cancelVideoCompression', {
        'compressionId': compressionId,
      });
      // Clean up regardless of result
      _progressCallbacks.remove(compressionId);
      _activeCompressions.remove(compressionId);
      return result ?? false;
    } on PlatformException {
      // Still clean up on error
      _progressCallbacks.remove(compressionId);
      _activeCompressions.remove(compressionId);
      rethrow;
    }
  }

  /// Get all active compression IDs (useful for debugging)
  static List<String> getActiveCompressions() {
    return List.from(_activeCompressions);
  }

  /// Get the last compression ID that was started
  /// Useful if you didn't use the onCompressionIdGenerated callback
  static String? getLastCompressionId() {
    return _lastCompressionId;
  }

  /// Cancel all active compressions
  static Future<void> cancelAllCompressions() async {
    final ids = List.from(_activeCompressions);
    for (final id in ids) {
      await cancelVideoCompression(id);
    }
  }
}
