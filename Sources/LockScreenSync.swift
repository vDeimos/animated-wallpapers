import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import OSLog
import VideoToolbox

private let logger = Logger(subsystem: "local.gifpapers.animated-wallpapers.lock-screen",
                            category: "sync")
private let appID = "local.gifpapers.animated-wallpapers"
private let provider = "com.apple.wallpaper.choice.aerials"
private let aerialPreferences = "com.apple.wallpaper.aerial" as CFString
private let overrideKey = "AerialManifestLocalPathOverride" as CFString
private let localOnlyKey = "AerialManifestForceLocal" as CFString
private let categoryID = "9A329B0F-1455-4CF0-9DF3-61CC9ED76004"
private let subcategoryID = "CE6B09CC-A9CA-4866-882F-6D1066242222"
private let files = FileManager.default

@main
struct LockScreenSync {
    static func main() async {
        do {
            try await synchronize()
        } catch {
            logger.error("Wallpaper sync failed: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }

    static func synchronize() async throws {
        guard let selection = Selection.current() else { return }
        let home = files.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support")
        let wallpaper = support.appending(path: "com.apple.wallpaper")
        let downloaded = wallpaper.appending(path: "aerials/manifest/entries.json")
        let bundled = URL(filePath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json")
        let manifestURL = wallpaper.appending(path: "aerials/animated-wallpapers/entries.json")
        CFPreferencesAppSynchronize(aerialPreferences)
        let existingOverride = CFPreferencesCopyAppValue(overrideKey, aerialPreferences) as? String
        if let existingOverride, !existingOverride.isEmpty, existingOverride != manifestURL.path {
            throw SyncError.catalogAlreadyOverridden
        }
        let storeURL = wallpaper.appending(path: "Store/Index.plist")
        let backup = support.appending(path: "Animated Wallpapers/Lock Screen/Original Settings")
        let assetID = try selection.assetID()
        let movies = wallpaper.appending(path: "aerials/videos")
        let thumbnails = wallpaper.appending(path: "aerials/thumbnails")
        let movie = movies.appending(path: assetID + ".mov")
        let thumbnail = thumbnails.appending(path: assetID + ".png")

        let nativeManifest = try readManifest(bundled)
        let downloadedManifest = try? readManifest(downloaded)
        let manifest = if let downloadedManifest,
                          (downloadedManifest["version"] as? Int ?? 0) >= (nativeManifest["version"] as? Int ?? 0) {
            downloadedManifest
        } else {
            nativeManifest
        }
        _ = try readStore(storeURL)
        try files.createDirectory(at: movies, withIntermediateDirectories: true)
        try files.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        if !files.fileExists(atPath: movie.path) {
            try await prepareMovie(selection.source, destination: movie)
        }
        if !files.fileExists(atPath: thumbnail.path) {
            try await writeThumbnail(movie, destination: thumbnail)
        }
        guard Selection.current() == selection else { return }

        let store = try readStore(storeURL)
        let priorCatalog = try? readManifest(manifestURL)
        let custom = (priorCatalog?["assets"] as? [[String: Any]] ?? []).filter {
            ($0["categories"] as? [String])?.contains(categoryID) == true
        }
        let updatedManifest = catalog(manifest, id: assetID, title: selection.title,
                                      movie: movie, thumbnail: thumbnail)
        let manifestChanged = priorCatalog.map {
            !NSDictionary(dictionary: $0).isEqual(to: updatedManifest)
        } ?? true
        let updatedStore = try select(assetID, in: store)
        let storeChanged = !NSDictionary(dictionary: store).isEqual(to: updatedStore)
        let preferencesChanged = existingOverride != manifestURL.path
            || CFPreferencesCopyAppValue(localOnlyKey, aerialPreferences) as? Bool != true
        guard manifestChanged || storeChanged || preferencesChanged else { return }

        if files.fileExists(atPath: downloaded.path) { try saveOriginal(downloaded, in: backup) }
        try saveOriginal(storeURL, in: backup)
        if manifestChanged {
            try files.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: updatedManifest,
                                                  options: [.sortedKeys, .withoutEscapingSlashes])
            try data.write(to: manifestURL, options: .atomic)
        }
        if preferencesChanged {
            CFPreferencesSetAppValue(overrideKey, manifestURL.path as CFString, aerialPreferences)
            CFPreferencesSetAppValue(localOnlyKey, kCFBooleanTrue, aerialPreferences)
            guard CFPreferencesAppSynchronize(aerialPreferences) else { throw SyncError.preferencesWriteFailed }
        }
        if storeChanged {
            let data = try PropertyListSerialization.data(fromPropertyList: updatedStore,
                                                         format: .binary, options: 0)
            try data.write(to: storeURL, options: .atomic)
        }

        let reload = Process()
        reload.executableURL = URL(filePath: "/usr/bin/killall")
        reload.arguments = ["-u", NSUserName(), "WallpaperAgent", "WallpaperAerialsExtension"]
        reload.standardOutput = FileHandle.nullDevice
        reload.standardError = FileHandle.nullDevice
        try reload.run()
        reload.waitUntilExit()
        logger.notice("Selected \(selection.filename, privacy: .public) for the macOS lock screen (\(assetID, privacy: .public))")

        // Keep the previous registration's files available while macOS switches renderers.
        // When a wallpaper is revisited it can reuse its prepared video.
        pruneOlderFiles(at: movies, thumbnails: thumbnails, keeping: Set([assetID] + custom.compactMap {
            $0["id"] as? String
        }))
    }

    static func readManifest(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let manifest = object as? [String: Any],
              manifest["assets"] is [[String: Any]], manifest["categories"] is [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    static func readStore(_ url: URL) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        guard let store = object as? [String: Any],
              store["AllSpacesAndDisplays"] is [String: Any], store["SystemDefault"] is [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return store
    }

    static func saveOriginal(_ url: URL, in directory: URL) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appending(path: url.lastPathComponent)
        if !files.fileExists(atPath: backup.path) {
            try Data(contentsOf: url).write(to: backup, options: .atomic)
        }
    }

    static func prepareMovie(_ source: URL, destination: URL) async throws {
        let folder = destination.deletingLastPathComponent()
        let segment = folder.appending(path: UUID().uuidString + ".mov")
        let repeated = folder.appending(path: UUID().uuidString + ".mov")
        defer {
            try? files.removeItem(at: segment)
            try? files.removeItem(at: repeated)
        }
        try await encodeAerialSegment(source, destination: segment)
        let minimumDuration = CMTime(seconds: 90, preferredTimescale: 600)
        let asset = AVURLAsset(url: segment)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let range = try await video.load(.timeRange)
        guard range.duration.seconds.isFinite, range.duration.seconds >= 0.2 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if range.duration >= minimumDuration {
            try files.moveItem(at: segment, to: destination)
            return
        }

        // Reuse the compressed frames so each source loop begins at a sync sample.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.featureUnsupported)
        }
        track.preferredTransform = try await video.load(.preferredTransform)
        var cursor = CMTime.zero
        while cursor < minimumDuration {
            try track.insertTimeRange(range, of: video, at: cursor)
            cursor = cursor + range.duration
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.featureUnsupported)
        }
        try await exporter.export(to: repeated, as: .mov)
        try files.moveItem(at: repeated, to: destination)
    }

    static func encodeAerialSegment(_ source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = try await video.load(.naturalSize)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rate = try await video.load(.nominalFrameRate)
        let fps = rate.isFinite && rate >= 10 ? Double(rate) : 30
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SyncError.encodingFailed }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let bitrate = max(4_000_000, min(12_000_000, Int(size.width * size.height * 1.2)))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.9,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                kVTCompressionPropertyKey_AllowOpenGOP as String: false,
                kVTCompressionPropertyKey_AllowTemporalCompression as String: true,
                kVTCompressionPropertyKey_BaseLayerFrameRate as String: fps / 2,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw SyncError.encodingFailed
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = try await video.load(.preferredTransform)
        guard writer.canAdd(input) else { throw SyncError.encodingFailed }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? SyncError.encodingFailed }
        guard writer.startWriting(), let first = output.copyNextSampleBuffer() else {
            reader.cancelReading()
            throw writer.error ?? reader.error ?? SyncError.encodingFailed
        }
        writer.startSession(atSourceTime: first.presentationTimeStamp)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }

        var sample: CMSampleBuffer? = first
        while let frame = sample {
            let deadline = ContinuousClock.now + .seconds(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw writer.error ?? SyncError.encodingFailed
                }
                try await Task.sleep(for: .milliseconds(4))
            }
            guard input.append(frame) else { throw writer.error ?? SyncError.encodingFailed }
            sample = output.copyNextSampleBuffer()
        }
        guard reader.status == .completed else { throw reader.error ?? SyncError.encodingFailed }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SyncError.encodingFailed }
    }

    static func writeThumbnail(_ source: URL, destination: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let (image, _) = try await generator.image(at: .zero)
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: destination, options: .atomic)
    }

    // Keep asset ownership recognizable without touching downloads that belong to Apple.
    static func pruneOlderFiles(at movies: URL, thumbnails: URL, keeping ids: Set<String>) {
        guard let urls = try? files.contentsOfDirectory(at: movies, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where url.pathExtension == "mov" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id.hasPrefix("9A329B0F-"), !ids.contains(id) else { continue }
            try? files.removeItem(at: url)
            try? files.removeItem(at: thumbnails.appending(path: id + ".png"))
        }
    }

    static func catalog(_ original: [String: Any], id: String, title: String,
                        movie: URL, thumbnail: URL) -> [String: Any] {
        var result = original
        var assets = (result["assets"] as? [[String: Any]] ?? []).filter {
            ($0["categories"] as? [String])?.contains(categoryID) != true
        }
        var categories = (result["categories"] as? [[String: Any]] ?? []).filter {
            $0["id"] as? String != categoryID
        }
        let group: [String: Any] = [
            "localizedNameKey": "Animated Wallpapers",
            "localizedDescriptionKey": "Animated Wallpapers",
            "previewImage": thumbnail.absoluteString,
            "representativeAssetID": id,
            "preferredOrder": 0,
        ]
        var subcategory = group
        subcategory["id"] = subcategoryID
        var category = group
        category["id"] = categoryID
        category["subcategories"] = [subcategory]
        categories.append(category)
        assets.append([
            "id": id,
            "accessibilityLabel": title,
            "localizedNameKey": title,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "includeInShuffle": false,
            "showInTopLevel": true,
            "pointsOfInterest": [String: String](),
            "preferredOrder": 0,
            "previewImage": thumbnail.absoluteString,
            "shotID": id,
            "url-4K-SDR-240FPS": movie.absoluteString,
        ])
        result["assets"] = assets
        result["categories"] = categories
        return result
    }

    static func select(_ id: String, in store: [String: Any]) throws -> [String: Any] {
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": id],
                                                               format: .binary, options: 0)
        let now = Date()
        let selection: [String: Any] = [
            "Content": [
                "Choices": [["Provider": provider, "Configuration": configuration, "Files": [Any]()]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
            "LastSet": now,
            "LastUse": now,
        ]

        func update(_ original: [String: Any]) -> [String: Any] {
            var entry = original
            if let linked = entry.removeValue(forKey: "Linked") {
                entry["Idle"] = linked
            }
            let content = (entry["Desktop"] as? [String: Any])?["Content"] as? [String: Any]
            let choices = content?["Choices"] as? [[String: Any]]
            let first = choices?.first
            if choices?.count == 1, first?["Provider"] as? String == provider,
               first?["Configuration"] as? Data == configuration, original["Type"] as? String == "individual" {
                return original
            }
            entry["Desktop"] = selection
            entry["Type"] = "individual"
            return entry
        }

        func updateGroups(_ group: [String: Any]) -> [String: Any] {
            if group["Idle"] != nil || group["Desktop"] != nil || group["Linked"] != nil {
                return update(group)
            }
            return group.mapValues { value in
                guard let nested = value as? [String: Any] else { return value }
                return updateGroups(nested)
            }
        }

        var result = store
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            if let entry = store[key] as? [String: Any] { result[key] = update(entry) }
        }
        for key in ["Spaces", "Displays"] {
            if let entries = store[key] as? [String: Any] { result[key] = updateGroups(entries) }
        }
        return result
    }
}

private enum SyncError: LocalizedError {
    case catalogAlreadyOverridden
    case preferencesWriteFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .catalogAlreadyOverridden: "Another wallpaper app is already providing a custom Aerial catalog."
        case .encodingFailed: "The native Aerial video could not be encoded."
        case .preferencesWriteFailed: "macOS did not save the custom Aerial catalog location."
        }
    }
}

private struct Selection: Equatable {
    let source: URL

    var filename: String { source.lastPathComponent }

    var title: String {
        let catalog = URL(filePath: "/Applications/Animated Wallpapers.app/Contents/Resources/Titles.plist")
        let titles = NSDictionary(contentsOf: catalog)
        return titles?[source.deletingPathExtension().lastPathComponent] as? String
            ?? source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized
    }

    static func current() -> Selection? {
        guard let name = CFPreferencesCopyAppValue("Wallpaper" as CFString, appID as CFString) as? String,
              !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            return nil
        }
        let configured = CFPreferencesCopyAppValue("WallpaperFolder" as CFString, appID as CFString) as? String
        let homeLibrary = files.homeDirectoryForCurrentUser.appending(path: "Pictures/Gifpapers/4K Wallpapers")
        let installedLibrary = URL(filePath: "/Library/Application Support/Animated Wallpapers/Library/4K Wallpapers",
                                   directoryHint: .isDirectory)
        let preferred = configured.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? homeLibrary
        let folders = [preferred, homeLibrary, installedLibrary]
        let source = folders.map { $0.appending(path: name) }.first { files.isReadableFile(atPath: $0.path) }
        return source.map { Selection(source: $0) }
    }

    func assetID() throws -> String {
        let attributes = try files.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.stringValue ?? ""
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let contentID = SHA256.hash(data: Data("hevc-temporal-v2\n\(source.path)\n\(size)\n\(modified)".utf8))
            .prefix(12).map { String(format: "%02X", $0) }
        return "9A329B0F-\(contentID[0..<2].joined())-\(contentID[2..<4].joined())-\(contentID[4..<6].joined())-\(contentID[6..<12].joined())"
    }
}
