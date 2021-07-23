import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  const ThumbnailConfig({
    this.quality = 100,
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

  static Future<File?> compressVideo(
    File file, {
    File? outputFile,
    bool saveToLibrary = false,
    VideoQuality quality = VideoQuality.very_low,
    void Function(double)? onVideoCompressProgress,
    ThumbnailConfig? thumbnailConfig,
  }) async {
    try {
      final str = quality.toString();
      final qstr = str.substring(str.indexOf('.') + 1);
      _onVideoCompressProgress = onVideoCompressProgress;
      final String? result = await _invokeMethod('compressVideo', {
        'path': file.path,
        'outputPath': outputFile?.path,
        'saveToLibrary': saveToLibrary,
        'quality': qstr.toUpperCase(),
        'storeThumbnail': thumbnailConfig != null,
        'thumbnailPath': thumbnailConfig?.file?.path,
        'thumbnailQuality': thumbnailConfig?.quality ?? 100,
      });
      _onVideoCompressProgress = null;
      return result == null ? null : File(result);
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

  static Future<bool?> saveToGallery(File file) async {
    final bool? result = await _invokeMethod('saveToGallery', {
      'path': file.path,
    });
    return result;
  }

  static Future<MediaInfo> getVideoInfo(
    File file,
  ) async {
    final json = await _invokeMethod('getVideoInfo', {
      'path': file.path,
    });
    return MediaInfo.fromJson(json);
  }

  static Future<void> _methodCallHandler(MethodCall call) {
    print(
      "MediaAssetsUtils:onMethodCall(method: ${call.method}, arguments: ${call.arguments})",
    );
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
