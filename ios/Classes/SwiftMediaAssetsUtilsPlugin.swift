import AVFoundation
import Flutter
import UIKit
import Photos

enum FileError: Error {
    case write
    case load
}

public enum DirectoryType: String {
    case movies = ".video"
    case pictures = ".image"
}

extension VideoQuality {
    var value: CGFloat {
        switch self {
        case .very_low:
            return 640
        case .low:
            return 640
        case .medium:
            return 960
        case .high:
            return 1280
        case .very_high:
            return 1920
        }
    }
}
public class SwiftMediaAssetsUtilsPlugin: NSObject, FlutterPlugin {
    
    
    private var videoExtension: [String] = ["mp4", "mov", "m4v", "3gp", "avi"]
    private var imageExtension: [String] = ["jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "heic", "heif"]
    
    private var channel: FlutterMethodChannel
    private var compressor: LightCompressor
    
    // Track multiple concurrent compressions
    private var compressions: [String: Compression] = [:]
    
    fileprivate var library: PHPhotoLibrary
    
    init(with registrar: FlutterPluginRegistrar) {
        channel = FlutterMethodChannel(name: "media_asset_utils", binaryMessenger: registrar.messenger())
        compressor = LightCompressor()
        library = PHPhotoLibrary.shared()
        super.init()
        channel.setMethodCallHandler(handle)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        _ = SwiftMediaAssetsUtilsPlugin(with: registrar)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        var dict: NSDictionary? = nil
        if (call.arguments != nil) {
            dict = (call.arguments as! NSDictionary)
        }
        switch call.method {
        case "compressVideo":
            let path: String = dict!.value(forKey: "path") as! String
            let outputPath: String = dict?.value(forKey: "outputPath") as? String ?? generatePath(type: DirectoryType.movies)
            let quality = VideoQuality.withLabel((dict?.value(forKey: "quality") as? String)?.lowercased() ?? "medium") ?? VideoQuality.medium
            let compressionId: String = dict?.value(forKey: "compressionId") as? String ?? UUID().uuidString
            
            let saveToLibrary: Bool = dict!.value(forKey: "saveToLibrary") as? Bool ?? false
            let storeThumbnail: Bool = dict!.value(forKey: "storeThumbnail") as? Bool ?? true
            let thumbnailPath: String? = dict!.value(forKey: "thumbnailPath") as? String
            let thumbnailQuality: CGFloat = CGFloat(dict!.value(forKey: "thumbnailQuality") as! Int ) / 100
            
            compressVideo(path, outputPath: outputPath, quality: quality, compressionId: compressionId) { [weak self] compressionResult in
                // Check if this compression still exists (wasn't cancelled)
                guard self?.compressions[compressionId] != nil else {
                    result(FlutterError(code: "VideoCompress", message: "The transcoding operation was canceled.", details: nil))
                    return
                }
                
                switch compressionResult {
                case .onSuccess(let url):
                    if (storeThumbnail) {
                        let _ = self?.storeThumbnailToFile(url: url, thumbnailPath: thumbnailPath, quality: thumbnailQuality, saveToLibrary: false)
                    }
                    result(url.path)
                    if (saveToLibrary) {
                        self?.library.save(videoAtURL: url)
                    }
                    
                case .onStart: break
                    
                case .onFailure(let error):
                    result(FlutterError(code: "VideoCompress", message: error.errorDescription, details: nil))
                    
                case .onCancelled:
                    // Clean up temporary files when cancelled
                    do {
                        if FileManager.default.fileExists(atPath: outputPath) {
                            try FileManager.default.removeItem(atPath: outputPath)
                        }
                    } catch {
                        print("Failed to remove temporary file: \(error)")
                    }
                    result(FlutterError(code: "VideoCompress", message: "The transcoding operation was canceled.", details: nil))
                }
                
                // Clean up the compression reference
                self?.compressions.removeValue(forKey: compressionId)
            }
        case "compressImage":
            let path: String = dict!.value(forKey: "path") as! String
            let outputPath: String = dict?.value(forKey: "outputPath") as? String ?? generatePath(type: DirectoryType.pictures)
            let saveToLibrary: Bool = dict!.value(forKey: "saveToLibrary") as? Bool ?? false
            let originalData: Data
            do {
                originalData = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                result(FlutterError(code: "ImageCompress", message: "Cannot load image data.", details: nil))
                return
            }
            guard let originalImage = UIImage(data: originalData) else {
                result(FlutterError(code: "ImageCompress", message: "Load image Failed.", details: nil))
                return
            }
            guard let data = originalImage.compressedData() else {
                result(FlutterError(code: "ImageCompress", message: "Compress image failed.", details: nil))
                return
            }
            
            do {
                let url = URL(fileURLWithPath: outputPath)
                createDirectory(url.deletingLastPathComponent())
                try data.write(to: url)
                result(url.path)
                if (saveToLibrary) {
                    library.save(imageAtURL: url)
                }
            } catch {
                result(FlutterError(code: "ImageCompress", message: "Store compress image failed.", details: nil))
            }
        case "getVideoThumbnail":
            let path: String = dict!.value(forKey: "path") as! String
            let thumbnailPath: String? = dict?.value(forKey: "thumbnailPath") as? String
            let quality: CGFloat = CGFloat(dict!.value(forKey: "quality") as! Int ) / 100
            let saveToLibrary: Bool = dict!.value(forKey: "saveToLibrary") as? Bool ?? false
            
            guard let thumbnail = storeThumbnailToFile(url: URL(fileURLWithPath: path), thumbnailPath: thumbnailPath, quality: quality, saveToLibrary: saveToLibrary) else {
                result(FlutterError(code: "VideoThumbnail", message: "Get video thumbnil failed.", details: nil))
                return
            }
            result(thumbnail)
        case "getVideoInfo":
            let path: String = dict!.value(forKey: "path") as! String
            let source = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: source)
            
            DispatchQueue(label: "getImageInfo", attributes: .concurrent).async {
                guard let videoTrack = asset.tracks(withMediaType: AVMediaType.video).first else {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "ExtractMetadata", message: "Cannot find video track.", details: nil))
                    }
                    return
                }
                let title = self.getMetaDataByTag(asset,key: "title")
                let author = self.getMetaDataByTag(asset,key: "author")
                let txf = videoTrack.preferredTransform
                let rotation = self.getVideoRotation(txf)
                let size = videoTrack.naturalSize.applying(txf)
                
                let dictionary = [
                    "path": path.replacingOccurrences(of: "file://", with: ""),
                    "title": title,
                    "author": author,
                    "width": abs(size.width),
                    "height": abs(size.height),
                    "duration": Int((CGFloat(asset.duration.value) / CGFloat(asset.duration.timescale)) * 1000),
                    "filesize": videoTrack.totalSampleDataLength,
                    "rotation": rotation,
                ] as [String : Any?]
                let data = try! JSONSerialization.data(withJSONObject: dictionary as NSDictionary, options: [])
                let jsonString = NSString(data: data as Data, encoding: String.Encoding.utf8.rawValue)
                DispatchQueue.main.async {
                    result(jsonString! as String)
                }
            }
        case "getImageInfo":
            let path: String = dict!.value(forKey: "path") as! String
            let source = URL(fileURLWithPath: path)
            DispatchQueue(label: "getImageInfo", attributes: .concurrent).async {
                let imageSourceRef = CGImageSourceCreateWithURL(source as CFURL, nil)
                var width: CGFloat?
                var height: CGFloat?
                var orientation: NSInteger?
                let filesize = try? source.resourceValues(forKeys: [URLResourceKey.fileSizeKey]).allValues.first?.value as? Int
                if let imageSRef = imageSourceRef {
                    let imageInfo = CGImageSourceCopyPropertiesAtIndex(imageSRef, 0, nil)
                    if let imageP = imageInfo {
                        let imageDict = imageP as Dictionary
                        width = imageDict[kCGImagePropertyPixelWidth] as? CGFloat
                        height = imageDict[kCGImagePropertyPixelHeight] as? CGFloat
                        orientation = imageDict[kCGImagePropertyOrientation] as? NSInteger
                        if (orientation == 5 || orientation == 6 || orientation == 7 || orientation == 8) {
                            let temp = width
                            width = height
                            height = temp
                        }
                        //                    if (orientation == 1 || orientation == 2) {
                        //                        degress = 0
                        //                    } else if (orientation == 3 || orientation == 4) {
                        //                        degress = 180
                        //                    } else if (orientation == 6 || orientation == 5) {
                        //                        degress = 90
                        //                    } else if (orientation == 8 || orientation == 7) {
                        //                        degress = 270
                        //                    }
                        //                    ismirror = orientation == 2 || orientation == 4 || orientation == 5 || orientation == 7
                    }
                }
                let dictionary = [
                    "path": path.replacingOccurrences(of: "file://", with: ""),
                    "width": width,
                    "height": height,
                    "filesize": filesize,
                    "orientation": orientation,
                ] as [String : Any?]
                let data = try! JSONSerialization.data(withJSONObject: dictionary as NSDictionary, options: [])
                let jsonString = NSString(data: data as Data, encoding: String.Encoding.utf8.rawValue)
                DispatchQueue.main.async {
                    result(jsonString! as String)
                }
            }
        case "saveFileToGallery":
          let path: String = dict!.value(forKey: "path") as! String
          saveFileToGallery(path)
          result(true)
        case "cancelVideoCompression":
            let compressionId: String = dict?.value(forKey: "compressionId") as? String ?? ""
            if let compression = compressions[compressionId] {
                compression.cancel = true
                compressions.removeValue(forKey: compressionId)
                result(true)
            } else {
                result(false)
            }
        default:
            result(FlutterError(code: "NoImplemented", message: "Handles a call to an unimplemented method.", details: nil))
        }
    }

    private func saveFileToGallery(_ path: String) ->Void {
      let url = URL(fileURLWithPath: path)
      let pathExtension = url.pathExtension.lowercased()
      
      if (imageExtension.contains(pathExtension)) {
          library.save(imageAtURL: url)
      } else if (videoExtension.contains(pathExtension)) {
          library.save(videoAtURL: url)
      }
    }
    
    private func getVideoRotation(_ txf: CGAffineTransform) -> Int {
        var rotation = 0
        if (txf.a == 0 && txf.b == 1.0 && txf.c == -1.0 && txf.d == 0) {
            // Portrait
            rotation = 90;
        } else if (txf.a == 0 && txf.b == -1.0 && txf.c == 1.0 && txf.d == 0){
            // PortraitUpsideDown
            rotation = 270;
        } else if (txf.a == 1.0 && txf.b == 0 && txf.c == 0 && txf.d == 1.0){
            // LandscapeRight
            rotation = 0;
        } else if (txf.a == -1.0 && txf.b == 0 && txf.c == 0 && txf.d == -1.0){
            // LandscapeLeft
            rotation = 180;
        }
        return rotation
    }
    
    private func getMetaDataByTag(_ asset:AVAsset, key:String)->String {
        for item in asset.commonMetadata {
            if item.commonKey?.rawValue == key {
                return item.stringValue ?? "";
            }
        }
        return ""
    }
    
    private func createDirectory(_ url: URL) -> Void {
        let manager = FileManager.default
        if (!manager.fileExists(atPath: url.path)) {
            try! manager.createDirectory(atPath: url.path, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private func checkAVTracks(asset: AVAsset, completion: ((AVKeyValueStatus) -> Void)? = nil) {
        let status:AVKeyValueStatus = asset.statusOfValue(forKey: #keyPath(AVAsset.tracks), error: nil)
        print(status.rawValue)
        if (status == .failed) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                self.checkAVTracks(asset: asset)
            }
        }
        if (status == .loaded) {
            completion?(status)
        }
    }
    
    private func loadTracks(asset: AVAsset, completion: ((AVKeyValueStatus) -> Void)? = nil) {
        asset.loadValuesAsynchronously(forKeys: [#keyPath(AVAsset.tracks)]) {
            DispatchQueue.main.async {
                self.checkAVTracks(asset: asset, completion: completion)
            }
        }
    }
    
    private func compressVideo(_ path: String, outputPath: String, quality: VideoQuality = VideoQuality.medium, compressionId: String, completion: @escaping (CompressionResult) -> ()) -> Void {
        let source = URL(fileURLWithPath: path)
        let destination = URL(fileURLWithPath: outputPath)
        createDirectory(destination.deletingLastPathComponent())
        
        // Register this compression ID immediately to avoid race conditions
        let placeholderCompression = Compression()
        compressions[compressionId] = placeholderCompression
        
        // Check if file format is MP4-compatible
        let fileExtension = source.pathExtension.lowercased()
        let mp4CompatibleFormats = ["mp4", "m4v"]
        let isMP4Compatible = mp4CompatibleFormats.contains(fileExtension)
        
        let asset = AVURLAsset(url: source)
        guard let videoTrack = asset.tracks(withMediaType: AVMediaType.video).first else {
            completion(.onFailure(CompressionError(title: "Cannot find video track.")))
            return
        }
        
        // FILE FORMAT CHECK: Always compress non-MP4 formats for player compatibility
        if !isMP4Compatible {
            NSLog("iOS Video Compress: FILE FORMAT CHECK - '\(fileExtension)' is not MP4-compatible. Will compress to MP4 format.")
            // Force compression to convert to MP4
            let configuredDestination = destination.deletingPathExtension().appendingPathExtension("mp4")
            compressWithConfiguration(source: source, destination: configuredDestination, quality: quality, compressionId: compressionId, completion: completion, skipDictionarySetup: true)
            return
        }
        
        // Get file info for decision making
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? UInt64) ?? 0
        let fileSizeMB = Double(fileSize) / 1_048_576.0
        
        NSLog("iOS Video Compress: ═══════════════════════════════════════")
        NSLog("iOS Video Compress: 📋 FILE INFO")
        NSLog("iOS Video Compress: • File size: %.2f MB", fileSizeMB)
        NSLog("iOS Video Compress: • Track data length: %.2f MB", Double(videoTrack.totalSampleDataLength) / 1_048_576.0)
        NSLog("iOS Video Compress: • Format: .\(fileExtension) (MP4-compatible: \(isMP4Compatible))")
        
        // Only skip compression for files that are ALREADY in MP4/M4V format
        // Skip files smaller than 7MB (only if already MP4-compatible)
        if isMP4Compatible && fileSizeMB < 7.0 {
            NSLog("iOS Video Compress: ❌ SKIP - File size %.2f MB < 7MB threshold (MP4-compatible) - returning original", fileSizeMB)
            completion(.onSuccess(source))
            return
        }
        
        let bitrate = videoTrack.estimatedDataRate
        let bitrateMbps = bitrate / 1_000_000.0
        let videoSize = videoTrack.naturalSize
        let originalWidth = abs(videoSize.width)
        let originalHeight = abs(videoSize.height)
        
        var width = originalWidth
        var height = originalHeight
        
        // Check if resize is needed
        let needsResize = width > quality.value || height > quality.value
        
        NSLog("iOS Video Compress: 🔢 COMPRESSION DECISION LOGIC:")
        NSLog("iOS Video Compress: • Source bitrate: %.2f Mbps", bitrateMbps)
        NSLog("iOS Video Compress: • Dimensions: %dx%d", Int(originalWidth), Int(originalHeight))
        NSLog("iOS Video Compress: • Quality target: %dpx", Int(quality.value))
        NSLog("iOS Video Compress: • Needs resize: %@", needsResize ? "YES" : "NO")
        
        // CRITICAL: Match Android logic - Skip ONLY if low bitrate AND no resize needed
        // This prevents skipping files that need resizing even if they have low bitrate
        if isMP4Compatible && (bitrateMbps < 2.0) && !needsResize {
            NSLog("iOS Video Compress: ❌ SKIP - Low bitrate (%.2f Mbps < 2Mbps) AND no resize needed - returning original", bitrateMbps)
            completion(.onSuccess(source))
            return
        }
        
        // Calculate output dimensions if resize is needed
        if needsResize {
            if (width > height) {
                height = height * quality.value / width
                width = quality.value
            } else if (height > width) {
                width = width * quality.value / height
                height = quality.value
            } else {
                width = quality.value
                height = quality.value
            }
            NSLog("iOS Video Compress: ✅ COMPRESS - Will resize from %dx%d to %dx%d", Int(originalWidth), Int(originalHeight), Int(width), Int(height))
        } else if bitrateMbps >= 5.0 {
            NSLog("iOS Video Compress: ✅ COMPRESS - High bitrate (%.2f Mbps >= 5Mbps) - will optimize", bitrateMbps)
        } else if bitrateMbps >= 2.0 && bitrateMbps < 5.0 {
            NSLog("iOS Video Compress: ❌ SKIP - Moderate bitrate (%.2f Mbps in 2-5 range) and no resize - returning original", bitrateMbps)
            completion(.onSuccess(source))
            return
        }
        
        // Proceed with normal MP4 compression
        compressWithConfiguration(source: source, destination: destination, quality: quality, compressionId: compressionId, videoWidth: width, videoHeight: height, completion: completion, skipDictionarySetup: true)
    }
    
    private func compressWithConfiguration(source: URL, destination: URL, quality: VideoQuality, compressionId: String, videoWidth: CGFloat = 0, videoHeight: CGFloat = 0, completion: @escaping (CompressionResult) -> (), skipDictionarySetup: Bool = false) {
        var width = videoWidth
        var height = videoHeight
        
        // Calculate dimensions if not provided
        if width == 0 || height == 0 {
            let asset = AVURLAsset(url: source)
            if let videoTrack = asset.tracks(withMediaType: AVMediaType.video).first {
                let videoSize = videoTrack.naturalSize
                width = abs(videoSize.width)
                height = abs(videoSize.height)
                
                if width >= quality.value || height >= quality.value {
                    if (width > height) {
                        height = height * quality.value / width
                        width = quality.value
                    } else if (height > width) {
                        width = width * quality.value / height
                        height = quality.value
                    } else {
                        width = quality.value
                        height = quality.value
                    }
                }
            }
        }
        
        // Create a placeholder compression object first to avoid race condition
        // This ensures the compressionId exists in the dictionary before the completion callback
        // Skip if already set up by the calling function
        if !skipDictionarySetup {
            let placeholderCompression = Compression()
            compressions[compressionId] = placeholderCompression
        }
        
        // Store the compression operation for this compression ID
        let compression = self.compressor.compressVideo(source: source, destination: destination, progressQueue: .main, progressHandler: { [weak self] progress in
            DispatchQueue.main.async {
                let v = Float(progress.fractionCompleted * 100)
                self?.channel.invokeMethod("onVideoCompressProgress", arguments: [
                    "compressionId": compressionId,
                    "progress": v > 100 ? 100 : v
                ])
            }
        }, configuration: Configuration(
            quality: quality, isMinBitRateEnabled: false, keepOriginalResolution: false, videoHeight: Int(height), videoWidth: Int(width), videoBitrate: Int(width * height * 25 * 0.07)
        ), completion: { result in
            // Don't remove from dictionary here - let the outer completion handler do it
            completion(result)
        })
        
        // Update with the actual compression object
        compressions[compressionId] = compression
    }

    
    func getThumbnailImage(url: URL) -> UIImage? {
        let asset: AVURLAsset = AVURLAsset.init(url: url)
        let gen: AVAssetImageGenerator = AVAssetImageGenerator.init(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let time: CMTime = CMTimeMakeWithSeconds(0, preferredTimescale: 600)
        do {
            let image: CGImage = try gen.copyCGImage(at: time, actualTime: nil)
            let thumb: UIImage = UIImage(cgImage: image)
            return thumb
        } catch {
            return nil
        }
    }
    
    func storeThumbnailToFile(url: URL, thumbnailPath: String? = nil, quality: CGFloat = 1.0, saveToLibrary: Bool = true) -> String? {
        // .mp4 -> .jpg
        var thumbURL: URL
        if (thumbnailPath != nil) {
            thumbURL = URL(fileURLWithPath: thumbnailPath!).deletingLastPathComponent()
        } else {
            thumbURL = url.deletingLastPathComponent()
        }
        createDirectory(thumbURL)
        if (thumbnailPath == nil) {
            let filename: String = url.deletingPathExtension().lastPathComponent
            thumbURL.appendPathComponent(filename + "_thumbnail.jpg")
        } else {
            thumbURL = URL(fileURLWithPath: thumbnailPath!)
        }
        // get thumb UIImage
        let thumbImage = self.getThumbnailImage(url: url)
        if (thumbImage != nil) {
            // store to file
            if let _ = thumbImage!.storeImageToFile(thumbURL.path, quality: quality) {
                if (saveToLibrary) {
                    library.save(imageAtURL: thumbURL)
                }
                return thumbURL.path
            }
        }
        return nil
    }
    
    private func generatePath(type: DirectoryType, filename: String? = nil) -> String {
        let ext = type == .movies ? ".mp4" : ".jpg"
        
        let manager = FileManager.default
        
        //        let paths = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        let paths = NSTemporaryDirectory()
        var cachesDir: URL = URL(fileURLWithPath: paths).appendingPathComponent( type.rawValue, isDirectory: true)
        
        if (!manager.fileExists(atPath: cachesDir.path)) {
            try! manager.createDirectory(atPath: cachesDir.path, withIntermediateDirectories: true, attributes: nil)
        }
        var name: String
        if (filename != nil) {
            name = filename!;
        } else {
            name = String(Int(Date().timeIntervalSince1970));
        }
        cachesDir.appendPathComponent(name + ext)
        
        return cachesDir.path
    }
}
