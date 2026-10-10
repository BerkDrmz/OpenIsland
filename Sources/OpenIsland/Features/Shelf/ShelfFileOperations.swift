import Foundation
import ImageIO
import IslandCore
import UniformTypeIdentifiers

/// Raf işlemlerinin dosya sistemi tarafı. Yalnızca public araçlar: `/usr/bin/ditto` (Finder'ın "Sıkıştır" ve
/// Arşiv İzlencesi'nin kullandığı biçim) ve ImageIO. Hepsi arka planda, ana iş parçacığı dışında çalışır;
/// kurallar (uygunluk, adlandırma, hedef boyut) `ShelfOperationRules` içindedir.
///
/// Çıktı, Finder'daki gibi orijinalin yanına yazılır; o klasör yazılamıyorsa rafın kendi klasörüne. Var olan hiçbir
/// dosyanın üzerine yazılmaz (benzersiz ad) ve orijinaller değiştirilmez.
enum ShelfFileOperations {
    struct Failure: Error {
        let message: String
    }

    static func info(for url: URL) -> ShelfFileInfo {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let name = url.lastPathComponent
        return ShelfFileInfo(name: name, isDirectory: isDirectory.boolValue,
                             isImage: !isDirectory.boolValue && ShelfOperationRules.isCompressibleImage(name: name))
    }

    /// İlk öğenin klasörü yazılabilirse orası, değilse `fallback` (rafın klasörü).
    static func outputFolder(for urls: [URL], fallback: URL) -> URL {
        guard let parent = urls.first?.deletingLastPathComponent(),
              FileManager.default.isWritableFile(atPath: parent.path) else { return fallback }
        return parent
    }

    // MARK: - Zip

    static func zip(_ urls: [URL], into folder: URL) throws -> URL {
        let name = ShelfOperationRules.uniqueName(ShelfOperationRules.archiveName(for: urls.map(info)), existing: names(in: folder))
        let destination = folder.appendingPathComponent(name)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        if urls.count == 1, let source = urls.first {
            let keepParent = info(for: source).isDirectory ? ["--keepParent"] : []
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc"] + keepParent + [source.path, destination.path])
            completed = true
            return destination
        }
        // Birden fazla öğe: arşivin kökünde yan yana dursunlar diye geçici bir klasöre klonlanır (APFS'te kopya
        // yer kaplamaz), klasörün içeriği arşivlenir.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("OpenIsland-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for url in urls {
            let target = staging.appendingPathComponent(ShelfOperationRules.uniqueName(url.lastPathComponent, existing: names(in: staging)))
            try FileManager.default.copyItem(at: url, to: target)
        }
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, destination.path])
        completed = true
        return destination
    }

    // MARK: - Arşivi aç

    /// Arşiv tek bir öğe (çoğunlukla bir klasör) içeriyorsa o öğe doğrudan yanına çıkar; iç içe "Proje/Proje"
    /// oluşmaz. Birden fazla öğe içeriyorsa arşivin adında bir klasöre açılır (Arşiv İzlencesi gibi).
    static func unzip(_ url: URL, into folder: URL) throws -> URL {
        let scratch = folder.appendingPathComponent(".openisland-açılıyor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try run("/usr/bin/ditto", ["-x", "-k", url.path, scratch.path])
        let contents = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0 != "__MACOSX" }
        let existing = names(in: folder)
        if contents.count == 1, let only = contents.first {
            let target = folder.appendingPathComponent(ShelfOperationRules.uniqueName(only, existing: existing))
            try FileManager.default.moveItem(at: scratch.appendingPathComponent(only), to: target)
            return target
        }
        let name = ShelfOperationRules.uniqueName(ShelfOperationRules.extractedFolderName(for: url.lastPathComponent), existing: existing)
        let target = folder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: scratch.appendingPathComponent("__MACOSX"))
        try FileManager.default.moveItem(at: scratch, to: target)
        return target
    }

    // MARK: - Resmi sıkıştır

    /// Sonuç orijinalden küçük değilse hiçbir dosya bırakılmaz ve `nil` döner.
    static func compressImage(_ url: URL, into folder: URL) throws -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure(message: "Görsel okunamadı") }
        let target = ShelfOperationRules.targetPixelSize(width: width, height: height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF yönü uygulanır
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure(message: "Görsel küçültülemedi")
        }
        // Alfa kanalı olması yetmez: macOS ekran görüntüleri alfa kanallı PNG'dir ama saydam pikselleri yoktur.
        // Yalnızca gerçekten saydam piksel varsa PNG kalır; yoksa JPEG'e çevrilir (asıl kazanç burada).
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool ?? false) && usesTransparency(image)
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("OpenIsland-\(UUID().uuidString).\(hasAlpha ? "png" : "jpg")")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let destination = CGImageDestinationCreateWithURL(scratch as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure(message: "Görsel yazılamadı")
        }
        // Konum gibi meta veriler taşınmaz; yalnızca piksel ve renk profili.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: ShelfOperationRules.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Görsel yazılamadı") }

        let originalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let resultBytes = (try? scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard ShelfOperationRules.keepsCompressedResult(originalBytes: originalBytes, resultBytes: resultBytes) else { return nil }
        let name = ShelfOperationRules.uniqueName(ShelfOperationRules.compressedImageName(for: url.lastPathComponent, hasAlpha: hasAlpha),
                                                  existing: names(in: folder))
        let output = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: scratch, to: output)
        return output
    }

    // MARK: - Yardımcılar

    /// Küçültülmüş görselde tamamen opak olmayan en az bir piksel var mı (tek geçiş, yalnızca işlem sırasında).
    private static func usesTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return true } // emin değilse saydamlığı koru
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for index in stride(from: 3, to: width * height * 4, by: 4) where bytes[index] < 255 { return true }
        return false
    }

    private static func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Drain while the child runs: a full stderr pipe otherwise blocks both processes.
        var errorData = Data()
        let diagnosticLimit = 64 * 1024
        while true {
            let chunk = errors.fileHandleForReading.readData(ofLength: 16 * 1024)
            if chunk.isEmpty { break }
            if errorData.count < diagnosticLimit {
                errorData.append(chunk.prefix(diagnosticLimit - errorData.count))
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(message: detail.isEmpty ? "İşlem başarısız" : detail)
        }
    }
}
