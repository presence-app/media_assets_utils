import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_asset_utils/media_asset_utils.dart';
import 'package:media_asset_utils_example/permission_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:video_player/video_player.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  File? outputFile;
  File? file;
  int? outputFileSize;
  int? fileSize;
  double _compressionProgress = 0;
  bool _isCompressing = false;
  String? _activeCompressionId;

  @override
  void initState() {
    super.initState();
  }

  Future<void> initThumbnail(BuildContext context) async {
    final bool isGranted = await GGPermissionUtil.album();
    if (isGranted) {
      final List<AssetEntity>? assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          requestType: RequestType.video,
          maxAssets: 1,
        ),
      );
      if ((assets ?? []).isNotEmpty) {
        file = await assets!.first.file;
        setState(() {
          fileSize = file!.lengthSync();
        });
        Directory? directory;
        // if (Platform.isIOS) {

        // } else {
        //   directory = (await getExternalStorageDirectories())!.first;
        // }
        directory = await getApplicationDocumentsDirectory();
        outputFile =
            File('${directory.path}/thumbnail_${Random().nextInt(100000)}.jpg');
        return;
      } else {
        throw Exception("No files selected");
      }
    }
    throw Exception("Permission denied");
  }

  Future<void> initCompress(BuildContext context, RequestType type) async {
    final bool isGranted = await GGPermissionUtil.album();
    if (isGranted) {
      final List<AssetEntity>? assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          requestType: type,
          maxAssets: 1,
        ),
      );
      if ((assets ?? []).isNotEmpty) {
        Directory? directory;

        directory = await getApplicationDocumentsDirectory();
        if (Platform.isIOS) {
          // directory = await getApplicationDocumentsDirectory();
          file = await assets!.first.originFile;
        } else {
          // directory = (await getExternalStorageDirectories())!.first;
          file = await assets!.first.file;
        }
        setState(() {
          fileSize = file!.lengthSync();
        });
        if (type == RequestType.video) {
          outputFile =
              File('${directory.path}/video_${Random().nextInt(100000)}.mp4');
        } else {
          Directory('${directory.path}/abdd/12233').createSync(recursive: true);
          outputFile = File('${directory.path}/abdd/12233/image_1.jpg');
        }
        return;
      } else {
        throw Exception("No files selected");
      }
    }
    throw Exception("Permission denied");
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Builder(builder: (_) {
          return Column(
            children: [
              Container(
                width: double.infinity,
                constraints: BoxConstraints(minHeight: 200),
                child: Column(
                  children: [
                    Text(
                        'Selected: $file, File size: ${fileSize != null ? (fileSize! / 1024 / 1024).toStringAsFixed(2) : 0} MB'),
                    Text(
                        'Output: $outputFile, File size: ${outputFileSize != null ? (outputFileSize! / 1024 / 1024).toStringAsFixed(2) : 0} MB'),
                  ],
                ),
              ),
              TextButton(
                onPressed: _isCompressing
                    ? null
                    : () async {
                        await initCompress(_, RequestType.video);
                        if (file == null) return;

                        print(
                            "═══════════════════════════════════════════════════");
                        print("🎬 VIDEO COMPRESSION STARTED");
                        print(
                            "═══════════════════════════════════════════════════");

                        // Get video info before compression
                        try {
                          final videoInfo =
                              await MediaAssetUtils.getVideoInfo(file!);
                          print("📄 INPUT FILE INFO:");
                          print("  • Path: ${file!.path}");
                          print("  • File exists: ${file!.existsSync()}");
                          print(
                              "  • File size: ${(file!.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB");
                          print("  • Video info: ${videoInfo.toJson()}");
                          print("  • Width: ${videoInfo.width}");
                          print("  • Height: ${videoInfo.height}");
                          print("  • Duration: ${videoInfo.duration}ms");
                          if (videoInfo.filesize != null) {
                            print(
                                "  • Filesize from metadata: ${(videoInfo.filesize! / 1024 / 1024).toStringAsFixed(2)} MB");
                          }
                        } catch (e) {
                          print("⚠️ Could not get video info: $e");
                        }

                        print("\n⚙️ COMPRESSION PARAMETERS:");
                        print("  • Quality: VideoQuality.high (720p)");
                        print("  • Custom bitrate: 5 Mbps");
                        print("  • Save to library: false");
                        print("  • Output path: ${outputFile?.path}");

                        setState(() {
                          _isCompressing = true;
                          _compressionProgress = 0;
                        });

                        final startTime = DateTime.now();

                        try {
                          print("\n🔄 Starting compression...\n");

                          // COMPRESS WITH LIGHTCOMPRESS OR FFMPEG
                          // FFmpeg is faster but the decode cause issue on android playback
                          // lightCompressor is very slow on android.
                          outputFile = await MediaAssetUtils.compressVideo(
                            file!,
                            customBitRate: 5,
                            saveToLibrary: false, //true,
                            // high is 720p (will resize from 1920 to 1280), very_high is 1080p
                            quality: VideoQuality.high,
                            thumbnailConfig: ThumbnailConfig(),
                            onVideoCompressProgress: (double progress) {
                              print(
                                  '📊 Compression progress: ${progress.toStringAsFixed(1)}%');
                              setState(() {
                                _compressionProgress = progress;
                              });
                            },
                            onCompressionIdGenerated: (String id) {
                              print("🆔 Compression ID generated: $id");
                              setState(() {
                                _activeCompressionId = id;
                              });
                            },
                          );

                          final endTime = DateTime.now();
                          final duration = endTime.difference(startTime);

                          if (outputFile != null) {
                            print(
                                "\n═══════════════════════════════════════════════════");
                            print("✅ COMPRESSION SUCCESSFUL");
                            print(
                                "═══════════════════════════════════════════════════");
                            print("📤 OUTPUT FILE INFO:");
                            print("  • Path: ${outputFile!.path}");
                            print(
                                "  • File exists: ${outputFile!.existsSync()}");
                            print(
                                "  • File size: ${(outputFile!.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB");
                            print(
                                "  • Original size: ${(file!.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB");
                            final reduction = ((file!.lengthSync() -
                                    outputFile!.lengthSync()) /
                                file!.lengthSync() *
                                100);
                            print(
                                "  • Size reduction: ${reduction.toStringAsFixed(1)}%");
                            print(
                                "  • Duration: ${duration.inSeconds}s (${duration.inMinutes}m ${duration.inSeconds % 60}s)");
                            print(
                                "═══════════════════════════════════════════════════\n");

                            // Try to get output video info
                            try {
                              final outputInfo =
                                  await MediaAssetUtils.getVideoInfo(
                                      outputFile!);
                              print("📹 OUTPUT VIDEO INFO:");
                              print("  • ${outputInfo.toJson()}");
                            } catch (e) {
                              print("⚠️ Could not get output video info: $e");
                            }
                          } else {
                            print("\n⚠️ Compression returned null output file");
                          }

                          if (mounted) {
                            setState(() {
                              if (outputFile != null)
                                outputFileSize = outputFile!.lengthSync();
                              _isCompressing = false;
                              _activeCompressionId = null;
                            });
                          }
                        } on PlatformException catch (e) {
                          final endTime = DateTime.now();
                          final duration = endTime.difference(startTime);

                          print(
                              "\n═══════════════════════════════════════════════════");
                          print("❌ PLATFORM EXCEPTION");
                          print(
                              "═══════════════════════════════════════════════════");
                          print("  • Code: ${e.code}");
                          print("  • Message: ${e.message}");
                          print("  • Details: ${e.details}");
                          print("  • Stack trace: ${e.stacktrace}");
                          print(
                              "  • Duration before error: ${duration.inSeconds}s");
                          print(
                              "═══════════════════════════════════════════════════\n");

                          // Check if this is a cancellation (expected behavior)
                          if (e.message != null &&
                              e.message!.contains("canceled")) {
                            print("ℹ️ Compression was cancelled by user");
                            if (mounted) {
                              setState(() {
                                _isCompressing = false;
                                _activeCompressionId = null;
                                _compressionProgress = 0;
                              });
                            }
                          } else {
                            // This is an unexpected error
                            print("🚨 Unexpected compression error: $e");
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        'Compression error: ${e.message}')),
                              );
                              setState(() {
                                _isCompressing = false;
                                _activeCompressionId = null;
                              });
                            }
                          }
                        } catch (e, stackTrace) {
                          final endTime = DateTime.now();
                          final duration = endTime.difference(startTime);

                          print(
                              "\n═══════════════════════════════════════════════════");
                          print("❌ GENERAL EXCEPTION");
                          print(
                              "═══════════════════════════════════════════════════");
                          print("  • Error: $e");
                          print("  • Type: ${e.runtimeType}");
                          print(
                              "  • Duration before error: ${duration.inSeconds}s");
                          print("  • Stack trace:\n$stackTrace");
                          print(
                              "═══════════════════════════════════════════════════\n");

                          if (mounted) {
                            setState(() {
                              _isCompressing = false;
                              _activeCompressionId = null;
                            });
                          }
                        }
                      },
                child: Text('Compress Video'),
              ),
              if (_isCompressing)
                Container(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    children: [
                      LinearProgressIndicator(
                          value: _compressionProgress / 100),
                      SizedBox(height: 8),
                      Text(
                          'Compression Progress: ${_compressionProgress.toStringAsFixed(1)}%'),
                      SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: () async {
                          if (_activeCompressionId != null) {
                            final cancelled =
                                await MediaAssetUtils.cancelVideoCompression(
                                    _activeCompressionId!);
                            if (cancelled) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text('Compression cancelled')),
                              );
                            }
                            if (mounted) {
                              setState(() {
                                _isCompressing = false;
                                _activeCompressionId = null;
                                _compressionProgress = 0;
                              });
                            }
                          }
                        },
                        icon: Icon(Icons.cancel),
                        label: Text('Cancel Compression'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              if (outputFile != null &&
                  outputFile!.existsSync() &&
                  !_isCompressing)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Builder(
                    builder: (btnContext) => ElevatedButton.icon(
                      onPressed: () {
                        _showMediaOverlay(btnContext);
                      },
                      icon: Icon(Icons.play_circle_filled),
                      label: Text('Open Compressed Media'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding:
                            EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                    ),
                  ),
                ),
              TextButton(
                onPressed: () async {
                  if (file == null) return;
                  await initThumbnail(_);
                  outputFile = await MediaAssetUtils.getVideoThumbnail(
                    file!,
                    quality: 50,
                    saveToLibrary: true,
                    thumbnailFile: outputFile!,
                  );
                  setState(() {
                    outputFileSize = outputFile!.lengthSync();
                    print("Compressed file size: $outputFileSize");
                  });
                },
                child: Text('Get Video Thumbnail'),
              ),
              TextButton(
                onPressed: () async {
                  await initCompress(_, RequestType.video);
                  final result = await MediaAssetUtils.getVideoInfo(file!);
                  print(result.toJson());
                },
                child: Text('Get Video Info'),
              ),
              TextButton(
                onPressed: () async {
                  await initCompress(_, RequestType.image);
                  final result = await MediaAssetUtils.getImageInfo(file!);
                  print(result.toJson());
                },
                child: Text('Get Image Info'),
              ),
              TextButton(
                onPressed: () async {
                  await initCompress(_, RequestType.image);

                  print(
                      "\n═══════════════════════════════════════════════════");
                  print("🖼️ IMAGE COMPRESSION STARTED");
                  print("═══════════════════════════════════════════════════");

                  try {
                    final imageInfo = await MediaAssetUtils.getImageInfo(file!);
                    print("📄 INPUT FILE INFO:");
                    print("  • Path: ${file!.path}");
                    print("  • File exists: ${file!.existsSync()}");
                    print(
                        "  • File size: ${(file!.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB");
                    print("  • Image info: ${imageInfo.toJson()}");
                    print("  • Width: ${imageInfo.width}");
                    print("  • Height: ${imageInfo.height}");
                  } catch (e) {
                    print("⚠️ Could not get image info: $e");
                  }

                  print("\n⚙️ COMPRESSION PARAMETERS:");
                  print("  • Save to library: true");
                  print("  • Output path: ${outputFile?.path}");

                  final startTime = DateTime.now();

                  try {
                    print("\n🔄 Starting compression...\n");

                    final result = await MediaAssetUtils.compressImage(
                      file!,
                      saveToLibrary: true,
                      outputFile: outputFile,
                    );

                    final endTime = DateTime.now();
                    final duration = endTime.difference(startTime);

                    print(
                        "\n═══════════════════════════════════════════════════");
                    print("✅ COMPRESSION SUCCESSFUL");
                    print(
                        "═══════════════════════════════════════════════════");
                    print("📤 OUTPUT FILE INFO:");
                    print("  • Result path: $result");
                    if (outputFile != null && outputFile!.existsSync()) {
                      print("  • File exists: ${outputFile!.existsSync()}");
                      print(
                          "  • File size: ${(outputFile!.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB");
                      print(
                          "  • Original size: ${(file!.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB");
                      final reduction =
                          ((file!.lengthSync() - outputFile!.lengthSync()) /
                              file!.lengthSync() *
                              100);
                      print(
                          "  • Size reduction: ${reduction.toStringAsFixed(1)}%");
                    }
                    print("  • Duration: ${duration.inMilliseconds}ms");
                    print(
                        "═══════════════════════════════════════════════════\n");

                    setState(() {
                      outputFileSize = outputFile!.lengthSync();
                    });
                  } catch (e, stackTrace) {
                    final endTime = DateTime.now();
                    final duration = endTime.difference(startTime);

                    print(
                        "\n═══════════════════════════════════════════════════");
                    print("❌ COMPRESSION ERROR");
                    print(
                        "═══════════════════════════════════════════════════");
                    print("  • Error: $e");
                    print("  • Type: ${e.runtimeType}");
                    print(
                        "  • Duration before error: ${duration.inMilliseconds}ms");
                    print("  • Stack trace:\n$stackTrace");
                    print(
                        "═══════════════════════════════════════════════════\n");
                  }
                },
                child: Text('Compress Image'),
              ),
              TextButton(
                onPressed: () async {
                  await initCompress(_, RequestType.image);
                  await MediaAssetUtils.saveToGallery(file!);
                },
                child: Text('Save To Media Store'),
              ),
              if (outputFile != null && outputFile!.existsSync())
                Builder(
                  builder: (btnContext) => TextButton(
                    onPressed: () {
                      _showMediaOverlay(btnContext);
                    },
                    child: Text('Open Compressed Media'),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  void _showMediaOverlay(BuildContext context) {
    final isVideo = outputFile!.path.toLowerCase().endsWith('.mp4') ||
        outputFile!.path.toLowerCase().endsWith('.mov') ||
        outputFile!.path.toLowerCase().endsWith('.m4v');

    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.all(10),
        child: Stack(
          children: [
            Center(
              child: isVideo
                  ? VideoPlayerWidget(videoFile: outputFile!)
                  : Image.file(
                      outputFile!,
                      fit: BoxFit.contain,
                    ),
            ),
            Positioned(
              top: 40,
              right: 20,
              child: IconButton(
                icon: Icon(Icons.close, color: Colors.white, size: 32),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VideoPlayerWidget extends StatefulWidget {
  final File videoFile;

  const VideoPlayerWidget({Key? key, required this.videoFile})
      : super(key: key);

  @override
  _VideoPlayerWidgetState createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.videoFile)
      ..initialize().then((_) {
        setState(() {
          _isInitialized = true;
        });
        _controller.play();
        _controller.setLooping(true);
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Center(child: CircularProgressIndicator());
    }

    return AspectRatio(
      aspectRatio: _controller.value.aspectRatio,
      child: GestureDetector(
        onTap: () {
          setState(() {
            if (_controller.value.isPlaying) {
              _controller.pause();
            } else {
              _controller.play();
            }
          });
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(_controller),
            if (!_controller.value.isPlaying)
              Icon(
                Icons.play_circle_outline,
                size: 80,
                color: Colors.white.withOpacity(0.8),
              ),
          ],
        ),
      ),
    );
  }
}
