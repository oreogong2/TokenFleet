/*
 * Dependency-free QR encoder used for local Swift share images.
 * Algorithm follows Project Nayuki's QR Code generator (MIT License):
 * Copyright (c) Project Nayuki. https://www.nayuki.io/page/qr-code-generator-library
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import CoreGraphics
import Foundation

enum LocalQRCodeGenerationError: Error {
    case payloadTooLong
    case dataLayoutFailed
}

enum LocalQRCodeGenerator {
    private struct Configuration {
        var version: Int
        var dataCodewords: Int
        var eccCodewords: Int
        var blocks: Int
        var byteCapacity: Int
    }

    private struct EncodedCodewords {
        var configuration: Configuration
        var codewords: [Int]
    }

    private struct ReedSolomonBlock {
        var data: [Int]
        var ecc: [Int]
    }

    private static let configurations = [
        // Version 6-L: 134-byte payload capacity.
        Configuration(
            version: 6,
            dataCodewords: 136,
            eccCodewords: 18,
            blocks: 2,
            byteCapacity: 134
        ),
        // Version 15-L: 520-byte payload capacity.
        Configuration(
            version: 15,
            dataCodewords: 523,
            eccCodewords: 22,
            blocks: 6,
            byteCapacity: 520
        ),
        // Version 40-L: 2,953-byte payload capacity.
        Configuration(
            version: 40,
            dataCodewords: 2_956,
            eccCodewords: 30,
            blocks: 25,
            byteCapacity: 2_953
        )
    ]

    static func makeCGImage(
        text: String,
        scale: Int = 8,
        quietZone: Int = 4
    ) -> CGImage? {
        guard scale > 0, quietZone >= 0,
              let modules = try? matrix(for: text),
              !modules.isEmpty
        else { return nil }

        let moduleCount = modules.count + (quietZone * 2)
        let pixelSize = moduleCount * scale
        let bytesPerRow = pixelSize * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * pixelSize)

        for y in modules.indices {
            for x in modules[y].indices where modules[y][x] {
                let startX = (x + quietZone) * scale
                let startY = (y + quietZone) * scale
                for pixelY in startY..<(startY + scale) {
                    for pixelX in startX..<(startX + scale) {
                        let offset = (pixelY * bytesPerRow) + (pixelX * 4)
                        pixels[offset] = 0
                        pixels[offset + 1] = 0
                        pixels[offset + 2] = 0
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func matrix(for text: String) throws -> [[Bool]] {
        let encoded = try encodeCodewords(text)
        let version = encoded.configuration.version
        let size = (version * 4) + 17
        var modules = Array(
            repeating: Array(repeating: false, count: size),
            count: size
        )
        var functions = modules

        func setFunction(x: Int, y: Int, dark: Bool) {
            guard x >= 0, y >= 0, x < size, y < size else { return }
            modules[y][x] = dark
            functions[y][x] = true
        }

        for index in 0..<size {
            setFunction(x: 6, y: index, dark: index.isMultiple(of: 2))
            setFunction(x: index, y: 6, dark: index.isMultiple(of: 2))
        }

        func drawFinder(centerX: Int, centerY: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let distance = max(abs(dx), abs(dy))
                    setFunction(
                        x: centerX + dx,
                        y: centerY + dy,
                        dark: distance != 2 && distance != 4
                    )
                }
            }
        }
        drawFinder(centerX: 3, centerY: 3)
        drawFinder(centerX: size - 4, centerY: 3)
        drawFinder(centerX: 3, centerY: size - 4)

        let alignments = alignmentPositions(version: version, size: size)
        for (xIndex, x) in alignments.enumerated() {
            for (yIndex, y) in alignments.enumerated() {
                let last = alignments.count - 1
                if (xIndex == 0 && yIndex == 0)
                    || (xIndex == 0 && yIndex == last)
                    || (xIndex == last && yIndex == 0) {
                    continue
                }
                for dy in -2...2 {
                    for dx in -2...2 {
                        setFunction(
                            x: x + dx,
                            y: y + dy,
                            dark: max(abs(dx), abs(dy)) != 1
                        )
                    }
                }
            }
        }

        if version >= 7 {
            var remainder = version
            for _ in 0..<12 {
                remainder = (remainder << 1) ^ (((remainder >> 11) & 1) * 0x1F25)
            }
            let versionBits = (version << 12) | remainder
            for index in 0..<18 {
                let color = bit(versionBits, at: index)
                let first = size - 11 + (index % 3)
                let second = index / 3
                setFunction(x: first, y: second, dark: color)
                setFunction(x: second, y: first, dark: color)
            }
        }

        let formatData = 0b01 << 3 // Error correction L, mask 0.
        var formatRemainder = formatData
        for _ in 0..<10 {
            formatRemainder = (formatRemainder << 1)
                ^ (((formatRemainder >> 9) & 1) * 0x537)
        }
        let formatBits = ((formatData << 10) | formatRemainder) ^ 0x5412
        for index in 0...5 {
            setFunction(x: 8, y: index, dark: bit(formatBits, at: index))
        }
        setFunction(x: 8, y: 7, dark: bit(formatBits, at: 6))
        setFunction(x: 8, y: 8, dark: bit(formatBits, at: 7))
        setFunction(x: 7, y: 8, dark: bit(formatBits, at: 8))
        for index in 9..<15 {
            setFunction(x: 14 - index, y: 8, dark: bit(formatBits, at: index))
        }
        for index in 0..<8 {
            setFunction(
                x: size - 1 - index,
                y: 8,
                dark: bit(formatBits, at: index)
            )
        }
        for index in 8..<15 {
            setFunction(
                x: 8,
                y: size - 15 + index,
                dark: bit(formatBits, at: index)
            )
        }
        setFunction(x: 8, y: size - 8, dark: true)

        var dataIndex = 0
        let dataBitCount = encoded.codewords.count * 8
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                let upward = ((right + 1) & 2) == 0
                let y = upward ? size - 1 - vertical : vertical
                for column in 0..<2 {
                    let x = right - column
                    if functions[y][x] { continue }
                    let raw = dataIndex < dataBitCount
                        ? bit(encoded.codewords[dataIndex >> 3], at: 7 - (dataIndex & 7))
                        : false
                    modules[y][x] = raw != ((x + y).isMultiple(of: 2))
                    if dataIndex < dataBitCount { dataIndex += 1 }
                }
            }
            right -= 2
        }
        guard dataIndex == dataBitCount else {
            throw LocalQRCodeGenerationError.dataLayoutFailed
        }
        return modules
    }

    private static func encodeCodewords(_ text: String) throws -> EncodedCodewords {
        let bytes = Array(text.utf8).map(Int.init)
        guard let configuration = configurations.first(where: {
            bytes.count <= $0.byteCapacity
        }) else {
            throw LocalQRCodeGenerationError.payloadTooLong
        }

        var bits: [Bool] = []
        appendBits(to: &bits, value: 0b0100, length: 4)
        appendBits(
            to: &bits,
            value: bytes.count,
            length: configuration.version < 10 ? 8 : 16
        )
        for byte in bytes {
            appendBits(to: &bits, value: byte, length: 8)
        }
        let capacity = configuration.dataCodewords * 8
        appendBits(to: &bits, value: 0, length: min(4, capacity - bits.count))
        while !bits.count.isMultiple(of: 8) { bits.append(false) }

        var data: [Int] = []
        var bitIndex = 0
        while bitIndex < bits.count {
            var byte = 0
            for offset in 0..<8 {
                byte = (byte << 1) | (bits[bitIndex + offset] ? 1 : 0)
            }
            data.append(byte)
            bitIndex += 8
        }
        var padIndex = 0
        while data.count < configuration.dataCodewords {
            data.append(padIndex.isMultiple(of: 2) ? 0xEC : 0x11)
            padIndex += 1
        }

        let rawCodewords = rawDataModules(version: configuration.version) / 8
        let shortBlocks = configuration.blocks - (rawCodewords % configuration.blocks)
        let shortBlockLength = rawCodewords / configuration.blocks
        let divisor = divisorFor(degree: configuration.eccCodewords)
        var blocks: [ReedSolomonBlock] = []
        var offset = 0
        for index in 0..<configuration.blocks {
            let dataLength = shortBlockLength - configuration.eccCodewords
                + (index < shortBlocks ? 0 : 1)
            let blockData = Array(data[offset..<(offset + dataLength)])
            offset += dataLength
            blocks.append(
                ReedSolomonBlock(
                    data: blockData,
                    ecc: remainderFor(data: blockData, divisor: divisor)
                )
            )
        }

        var codewords: [Int] = []
        let maximumDataLength = blocks.map(\.data.count).max() ?? 0
        for index in 0..<maximumDataLength {
            for block in blocks where index < block.data.count {
                codewords.append(block.data[index])
            }
        }
        for index in 0..<configuration.eccCodewords {
            for block in blocks {
                codewords.append(block.ecc[index])
            }
        }
        return EncodedCodewords(
            configuration: configuration,
            codewords: codewords
        )
    }

    private static func appendBits(
        to target: inout [Bool],
        value: Int,
        length: Int
    ) {
        guard length > 0 else { return }
        for shift in stride(from: length - 1, through: 0, by: -1) {
            target.append(((value >> shift) & 1) != 0)
        }
    }

    private static func multiply(_ x: Int, _ y: Int) -> Int {
        var result = 0
        for index in stride(from: 7, through: 0, by: -1) {
            result = (result << 1) ^ (((result >> 7) & 1) * 0x11D)
            result ^= ((y >> index) & 1) * x
        }
        return result
    }

    private static func divisorFor(degree: Int) -> [Int] {
        var result = [Int](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root = 1
        for _ in 0..<degree {
            for offset in 0..<degree {
                result[offset] = multiply(result[offset], root)
                if offset + 1 < degree {
                    result[offset] ^= result[offset + 1]
                }
            }
            root = multiply(root, 2)
        }
        return result
    }

    private static func remainderFor(data: [Int], divisor: [Int]) -> [Int] {
        var result = [Int](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for index in result.indices {
                result[index] ^= multiply(divisor[index], factor)
            }
        }
        return result
    }

    private static func rawDataModules(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignments = (version / 7) + 2
            result -= (25 * alignments - 10) * alignments - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    private static func bit(_ value: Int, at index: Int) -> Bool {
        ((value >> index) & 1) != 0
    }

    private static func alignmentPositions(version: Int, size: Int) -> [Int] {
        if version == 1 { return [] }
        let count = (version / 7) + 2
        let step = ((version * 8 + count * 3 + 5) / (count * 4 - 4)) * 2
        var result = [6]
        var position = size - 7
        while result.count < count {
            result.insert(position, at: 1)
            position -= step
        }
        return result
    }
}
