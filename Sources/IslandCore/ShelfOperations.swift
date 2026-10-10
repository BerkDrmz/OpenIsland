/// Raftaki dosyalara uygulanabilen işlemler.
public enum ShelfOperation: String, Sendable, CaseIterable {
    /// Seçili öğeleri tek bir zip arşivinde toplar (Finder'daki "Sıkıştır" gibi).
    case zip
    /// Zip arşivini yanına açar.
    case unzip
    /// Görselin boyutunu küçültür (uzun kenar sınırı + JPEG kalitesi).
    case compressImage
    /// Dosya yollarını metin olarak panoya kopyalar.
    case copyPath

    public var title: String {
        switch self {
        case .zip: "Zip'le"
        case .unzip: "Arşivi aç"
        case .compressImage: "Resmi sıkıştır"
        case .copyPath: "Yolu kopyala"
        }
    }
}

/// İşlem kurallarının ihtiyaç duyduğu dosya özeti (dosya sistemine burada dokunulmaz).
public struct ShelfFileInfo: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var isImage: Bool

    public init(name: String, isDirectory: Bool = false, isImage: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isImage = isImage
    }

    var pathExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    var baseName: String {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }
}

/// Raf işlemlerinin kuralları (saf, test edilir): hangi işlem uygun, çıktı adı, görsel hedef boyutu.
public enum ShelfOperationRules {
    /// Sıkıştırılan görselin uzun kenarı en fazla bu kadar piksel olur.
    public static let maximumImageDimension = 2560
    /// JPEG kalitesi (0...1): gözle ayırt edilmesi zor, boyutu belirgin küçültür.
    public static let jpegQuality = 0.75

    /// Sıkıştırılabilen raster görseller. GIF (animasyon kaybolur) ve SVG (vektör) bilerek dışarıda.
    public static let compressibleImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "webp"]

    public static func isCompressibleImage(name: String) -> Bool {
        compressibleImageExtensions.contains(ShelfFileInfo(name: name).pathExtension)
    }

    /// Seçime uygun işlemler, menüde gösterilecek sırayla.
    public static func available(for files: [ShelfFileInfo]) -> [ShelfOperation] {
        guard !files.isEmpty else { return [] }
        var operations: [ShelfOperation] = [.zip]
        if files.allSatisfy({ !$0.isDirectory && $0.pathExtension == "zip" }) { operations.append(.unzip) }
        if files.allSatisfy({ !$0.isDirectory && $0.isImage }) { operations.append(.compressImage) }
        operations.append(.copyPath)
        return operations
    }

    /// Zip arşivinin adı: tek öğede öğenin adı (uzantısız), birden fazlasında Finder gibi "Arşiv".
    public static func archiveName(for files: [ShelfFileInfo]) -> String {
        guard files.count == 1, let file = files.first else { return "Arşiv.zip" }
        return file.baseName + ".zip"
    }

    /// Açılan arşivin klasör adı: arşivin adı, uzantısız.
    public static func extractedFolderName(for zipName: String) -> String {
        ShelfFileInfo(name: zipName).baseName
    }

    /// Sıkıştırılmış görselin adı. Gerçekten saydam pikseli olan görsel PNG kalır (JPEG saydamlığı taşımaz);
    /// alfa kanalı olup saydam pikseli olmayan (ör. macOS ekran görüntüsü) JPEG'e çevrilir.
    public static func compressedImageName(for name: String, hasAlpha: Bool) -> String {
        ShelfFileInfo(name: name).baseName + " (sıkıştırılmış)." + (hasAlpha ? "png" : "jpg")
    }

    /// Hedef piksel boyutu: en-boy oranı korunur, uzun kenar sınırı aşılmaz, büyütme yapılmaz.
    public static func targetPixelSize(width: Int, height: Int, maxDimension: Int = maximumImageDimension) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxDimension, longest > 0 else { return (width, height) }
        let scale = Double(maxDimension) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Klasörde çakışmayan ad: "Arşiv.zip", "Arşiv 2.zip", "Arşiv 3.zip"…
    public static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let info = ShelfFileInfo(name: name)
        let ext = info.pathExtension.isEmpty ? "" : "." + String(name.split(separator: ".").last ?? "")
        var index = 2
        while true {
            let candidate = "\(info.baseName) \(index)\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// Sıkıştırma sonucu tutulur mu: yalnızca orijinalden gerçekten küçükse (aksi halde kullanıcıya daha büyük bir
    /// "sıkıştırılmış" kopya bırakılmaz).
    public static func keepsCompressedResult(originalBytes: Int, resultBytes: Int) -> Bool {
        resultBytes > 0 && resultBytes < originalBytes
    }
}
