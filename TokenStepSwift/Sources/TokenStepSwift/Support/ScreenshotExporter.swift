import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct ScreenshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isScreenshotRendering: Bool {
        get { self[ScreenshotRenderingKey.self] }
        set { self[ScreenshotRenderingKey.self] = newValue }
    }
}

enum ScreenshotExportError: LocalizedError {
    case renderFailed
    case pngEncodingFailed
    case jpgEncodingFailed
    case clipboardWriteFailed
    case downloadsUnavailable
    case fileWriteFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return L("分享图片渲染失败，请重试；统计数据没有丢失。")
        case .pngEncodingFailed:
            return L("分享图片 PNG 编码失败，请重试。")
        case .jpgEncodingFailed:
            return L("分享图片 JPG 编码失败，请重试。")
        case .clipboardWriteFailed:
            return L("分享图片已生成，但写入剪贴板失败；请改用下载。")
        case .downloadsUnavailable:
            return L("找不到可写的下载目录，请检查文件权限。")
        case .fileWriteFailed:
            return L("分享图片已生成，但保存失败；请检查目标目录权限。")
        }
    }
}

@MainActor
protocol ScreenshotClipboardWriting {
    func replacePNG(with data: Data) -> Bool
}

@MainActor
struct GeneralScreenshotClipboardWriter: ScreenshotClipboardWriting {
    func replacePNG(with data: Data) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}

@MainActor
enum ScreenshotExporter {
    static func copy<V: View>(
        _ view: V,
        clipboardWriter: ScreenshotClipboardWriting? = nil
    ) throws {
        defer { MemoryPressure.relieveAllocatorPressure() }
        let image = try renderImage(view)
        let data = try pngData(from: image)
        let writer = clipboardWriter ?? GeneralScreenshotClipboardWriter()
        guard writer.replacePNG(with: data) else {
            throw ScreenshotExportError.clipboardWriteFailed
        }
    }

    static func save<V: View>(_ view: V, suggestedFileName: String) throws {
        defer { MemoryPressure.relieveAllocatorPressure() }
        let image = try renderImage(view)
        let data = try pngData(from: image)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ScreenshotExportError.fileWriteFailed
        }
    }

    @discardableResult
    static func saveJPGToDownloads<V: View>(
        _ view: V,
        downloadsDirectory: URL? = nil,
        revealInFinder: Bool = true
    ) throws -> URL {
        defer { MemoryPressure.relieveAllocatorPressure() }
        let image = try renderImage(view)
        let data = try jpgData(from: image)
        let url = try uniqueDownloadsURL(in: downloadsDirectory)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ScreenshotExportError.fileWriteFailed
        }
        if revealInFinder {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return url
    }

    static func suggestedFileName(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "TokenFleet-\(prefix)-\(formatter.string(from: Date())).png"
    }

    static func renderImage<V: View>(_ view: V) throws -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else {
            throw ScreenshotExportError.renderFailed
        }
        return image
    }

    static func pngData(from image: NSImage) throws -> Data {
        guard let bitmap = bitmapRepresentation(from: image),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotExportError.pngEncodingFailed
        }
        return data
    }

    static func jpgData(from image: NSImage) throws -> Data {
        guard let bitmap = bitmapRepresentation(from: image),
              let data = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.94]
              ) else {
            throw ScreenshotExportError.jpgEncodingFailed
        }
        return data
    }

    private static func bitmapRepresentation(from image: NSImage) -> NSBitmapImageRep? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard image.size.width > 0,
              image.size.height > 0,
              let cgImage = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: [.interpolation: NSImageInterpolation.high]
              )
        else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private static func uniqueDownloadsURL(in explicitDirectory: URL?) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd"
        let baseName = "TokenFleet\(formatter.string(from: Date()))"

        guard let downloads = explicitDirectory ?? FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            throw ScreenshotExportError.downloadsUnavailable
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: downloads.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: downloads.path)
        else {
            throw ScreenshotExportError.downloadsUnavailable
        }

        var candidate = downloads.appendingPathComponent("\(baseName).jpg")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent("\(baseName)-\(index).jpg")
            index += 1
        }
        return candidate
    }
}
