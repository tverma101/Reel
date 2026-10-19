//
//  ThumbnailCache.swift
//  iina
//
//  Created by lhc on 14/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate let subsystem = Logger.makeSubsystem("thumbcache", ["photo.stack"])

class ThumbnailCache {
  private typealias CacheVersion = UInt8
  private typealias FileSize = UInt64
  private typealias FileTimestamp = Int64

  private static let version: CacheVersion = 2
  
  private static let sizeofMetadata = MemoryLayout<CacheVersion>.size + MemoryLayout<FileSize>.size + MemoryLayout<FileTimestamp>.size

  private static let imageProperties: [NSBitmapImageRep.PropertyKey: Any] = [
    .compressionFactor: 0.75
  ]
  
  private static func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }

  static func fileExists(forName name: String) -> Bool {
    return FileManager.default.fileExists(atPath: urlFor(name).path)
  }

  static func fileIsCached(forName name: String, forVideo videoPath: URL?) -> Bool {
    guard let videoPath,
          let fileAttr = try? FileManager.default.attributesOfItem(atPath: videoPath.path) else {
      log("Cannot get video file attributes", level: .error)
      return false
    }

    // file size
    guard let fileSize = fileAttr[.size] as? FileSize else {
      log("Cannot get video file size", level: .error)
      return false
    }

    // modified date
    guard let fileModifiedDate = fileAttr[.modificationDate] as? Date else {
      log("Cannot get video file modification date", level: .error)
      return false
    }
    let fileTimestamp = FileTimestamp(fileModifiedDate.timeIntervalSince1970)

    // Check metadate in the cache
    if self.fileExists(forName: name) {
      guard let file = try? FileHandle(forReadingFrom: urlFor(name)) else {
        log("Cannot open cache file.", level: .error)
        return false
      }

      defer { file.closeFile() }
      let cacheVersion = file.read(type: CacheVersion.self)
      if cacheVersion != version { return false }

      return file.read(type: FileSize.self) == fileSize &&
        file.read(type: FileTimestamp.self) == fileTimestamp
    }

    return false
  }

  /// Write thumbnail cache to file.
  /// This method is expected to be called when the file doesn't exist.
  static func write(_ thumbnails: [FFThumbnail], forName name: String, forVideo videoPath: URL?) {
    log("Writing thumbnail cache...")
    let maxCacheSize = Preference.integer(for: .maxThumbnailPreviewCacheSize) *
      FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue
    guard maxCacheSize > 0 else { return }
    guard let videoPath,
          let attributes = try? FileManager.default.attributesOfItem(atPath: videoPath.path),
          let fileSize = attributes[.size] as? FileSize,
          let modifiedDate = attributes[.modificationDate] as? Date else {
      log("Cannot get video file attributes", level: .error)
      return
    }
    let pathURL = urlFor(name)
    guard FileManager.default.createFile(atPath: pathURL.path, contents: nil, attributes: nil) else {
      log("Cannot create file.", level: .error)
      return
    }
    guard let file = try? FileHandle(forWritingTo: pathURL) else {
      log("Cannot write to file.", level: .error)
      try? FileManager.default.removeItem(at: pathURL)
      CacheManager.shared.invalidate()
      return
    }
    var closed = false
    var completed = false
    defer {
      if !closed { file.closeFile() }
      if !completed {
        try? FileManager.default.removeItem(at: pathURL)
        CacheManager.shared.invalidate()
      }
    }

    file.write(Data(bytesOf: version))
    file.write(Data(bytesOf: fileSize))
    let fileTimestamp = FileTimestamp(modifiedDate.timeIntervalSince1970)
    file.write(Data(bytesOf: fileTimestamp))

    for thumbnail in thumbnails {
      let timestampData = Data(bytesOf: thumbnail.realTime)
      guard let tiffData = thumbnail.image?.tiffRepresentation,
            let jpegData = NSBitmapImageRep(data: tiffData)?.representation(
              using: .jpeg, properties: imageProperties) else {
        log("Cannot encode thumbnail.", level: .error)
        return
      }
      let blockLength = Int64(timestampData.count + jpegData.count)
      file.write(Data(bytesOf: blockLength))
      file.write(timestampData)
      file.write(jpegData)
    }

    file.closeFile()
    closed = true
    completed = true
    CacheManager.shared.invalidate()
    if CacheManager.shared.getCacheSize() > maxCacheSize {
      CacheManager.shared.clearOldCache()
    }
    log("Finished writing thumbnail cache.")
  }

  /// Read thumbnail cache to file.
  /// This method is expected to be called when the file exists.
  static func read(forName name: String) -> [FFThumbnail]? {
    log("Reading thumbnail cache...")

    let pathURL = urlFor(name)
    guard let file = try? FileHandle(forReadingFrom: pathURL) else {
      log("Cannot open file.", level: .error)
      return nil
    }
    log("Reading from \(pathURL.path)")

    var result: [FFThumbnail] = []

    // get file length
    file.seekToEndOfFile()
    let eof = file.offsetInFile

    // skip metadata
    guard eof >= UInt64(sizeofMetadata) else {
      file.closeFile()
      deleteCacheFile(at: pathURL)
      return nil
    }
    file.seek(toFileOffset: UInt64(sizeofMetadata))

    // data blocks
    while file.offsetInFile < eof {
      // length and timestamp
      guard let blockLength = file.read(type: Int64.self),
            let timestamp = file.read(type: Double.self),
            blockLength >= Int64(MemoryLayout<Double>.size),
            blockLength <= 64 * 1024 * 1024,
            file.offsetInFile <= eof,
            UInt64(blockLength - Int64(MemoryLayout<Double>.size)) <= eof - file.offsetInFile else {
        log("Cannot read image header. Cache file will be deleted.", level: .warning)
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      // jpeg
      let jpegLength = Int(blockLength) - MemoryLayout<Double>.size
      let jpegData = file.readData(ofLength: jpegLength)
      guard jpegData.count == jpegLength, let image = NSImage(data: jpegData) else {
        log("Cannot read image. Cache file will be deleted.", level: .warning)
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      // construct
      let tb = FFThumbnail()
      tb.realTime = timestamp
      tb.image = image
      result.append(tb)
    }

    file.closeFile()
    log("Finished reading thumbnail cache, \(result.count) in total")
    return result
  }

  static func clearThumbnailCache() {
    try? FileManager.default.removeItem(atPath: Utility.thumbnailCacheURL.path)
    Utility.createDirIfNotExist(url: Utility.thumbnailCacheURL)
    CacheManager.shared.invalidate()
  }

  private static func deleteCacheFile(at pathURL: URL) {
    // try deleting corrupted cache
    do {
      try FileManager.default.removeItem(at: pathURL)
      CacheManager.shared.invalidate()
    } catch {
      log("Cannot delete corrupted cache.", level: .error)
    }
  }

  private static func urlFor(_ name: String) -> URL {
    return Utility.thumbnailCacheURL.appendingPathComponent(name)
  }

}
