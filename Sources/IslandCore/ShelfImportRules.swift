import Foundation
import UniformTypeIdentifiers

/// Pure file-import rules used by the shelf so drag-and-drop keeps the supplied bytes and type.
public enum ShelfImportRules {
    public struct ImageRepresentation: Sendable, Equatable {
        public let data: Data
        public let fileExtension: String

        public init(data: Data, fileExtension: String) {
            self.data = data
            self.fileExtension = fileExtension
        }
    }

    /// Prefer a real file URL/file promise. This handles only raw image representations advertised by the drag source.
    public static func imageRepresentation(from representations: [String: Data]) -> ImageRepresentation? {
        for (type, fileExtension) in [(UTType.png.identifier, "png"), (UTType.tiff.identifier, "tiff")] {
            if let data = representations[type], !data.isEmpty {
                return ImageRepresentation(data: data, fileExtension: fileExtension)
            }
        }
        return nil
    }

    /// A supplied filename is authoritative, including case and an absent extension.
    public static func preferredFileExtension(typeIdentifier: String, suggestedFilename: String?,
                                              temporaryFileExtension: String) -> String {
        if let suggestedFilename {
            return (suggestedFilename as NSString).pathExtension
        }
        return temporaryFileExtension
    }

    /// Do not choose a converted image representation just because it is advertised first.
    /// If the provider only offers a known, conflicting type, fail without renaming bytes.
    public static func fileRepresentationType(_ identifiers: [String], suggestedFilename: String?) -> String? {
        let candidates = identifiers.filter {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
                && (suggestedFilename != nil || !type.conforms(to: .plainText))
        }
        if candidates.contains(UTType.data.identifier) { return UTType.data.identifier }
        if let name = suggestedFilename,
           let expected = UTType(filenameExtension: (name as NSString).pathExtension),
           !expected.isDynamic {
            return candidates.first {
                guard let type = UTType($0) else { return false }
                return type.conforms(to: expected) || expected.conforms(to: type)
            }
        }
        return candidates.first
    }

    public static func preservedFilename(suggested: String?, temporaryURL: URL) -> String? {
        let name = suggested ?? temporaryURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else { return nil }
        return name
    }

    /// A separate destination per import preserves the entire name (including .tar.gz),
    /// avoids concurrent name collisions, and never modifies the provider's source.
    public static func copyRepresentation(at source: URL, suggestedFilename: String?, into storage: URL) throws -> URL {
        guard source.isFileURL,
              let name = preservedFilename(suggested: suggestedFilename, temporaryURL: source) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let folder = storage.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
