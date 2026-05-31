import CoreGraphics
import CoreVideo
import Foundation

struct TextRegion: Sendable, Equatable {
    let pixelRect: CGRect
    let normalizedRect: CGRect
    /// Higher = more text-like cells per unit area (used to OCR likely PII regions first).
    let textnessScore: Double

    init(pixelRect: CGRect, normalizedRect: CGRect, textnessScore: Double = 0) {
        self.pixelRect = pixelRect
        self.normalizedRect = normalizedRect
        self.textnessScore = textnessScore
    }
}

struct TextRegionAnalysis: Sendable, Equatable {
    let roiRegions: [TextRegion]
    let yodoMaskRegions: [TextRegion]
    let roiCoverage: Double
    let yodoMaskCoverage: Double

    static let empty = TextRegionAnalysis(
        roiRegions: [],
        yodoMaskRegions: [],
        roiCoverage: 0,
        yodoMaskCoverage: 0
    )
}

enum TextRegionDetector {
    private static let columns = 48
    private static let edgeThreshold = 24
    private static let minContrast = 42
    private static let minEdgeDensity = 0.065
    private static let maxEdgeDensity = 0.72
    private static let minClusterCells = 2
    private static let maxRegions = 16
    private static let maxRegionCoverage = 0.92

    static func analyze(pixelBuffer: CVPixelBuffer) -> TextRegionAnalysis {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return .empty }
        guard let layout = PackedPixelLayout.layout(for: CVPixelBufferGetPixelFormatType(pixelBuffer)) else {
            return .empty
        }

        let gridColumns = max(1, min(columns, width))
        let rows = max(1, min(height, Int(round(Double(gridColumns) * Double(height) / Double(width)))))
        let cellWidth = max(1, Int(ceil(Double(width) / Double(gridColumns))))
        let cellHeight = max(1, Int(ceil(Double(height) / Double(rows))))
        var textCells = Array(repeating: false, count: gridColumns * rows)

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return .empty }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            return .empty
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<rows {
            for column in 0..<gridColumns {
                let rect = CGRect(
                    x: column * cellWidth,
                    y: row * cellHeight,
                    width: min(cellWidth, width - column * cellWidth),
                    height: min(cellHeight, height - row * cellHeight)
                )
                guard rect.width > 2, rect.height > 2 else { continue }
                if isTextLikeCell(
                    rect: rect,
                    base: base,
                    bytesPerRow: bytesPerRow,
                    layout: layout,
                    width: width,
                    height: height
                ) {
                    textCells[row * gridColumns + column] = true
                }
            }
        }

        let clusters = connectedClusters(cells: textCells, columns: gridColumns, rows: rows)
        let roiRegions = regions(
            from: clusters,
            columns: gridColumns,
            width: width,
            height: height,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            paddingCells: 0.75
        )
        let yodoRegions = regions(
            from: clusters,
            columns: gridColumns,
            width: width,
            height: height,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            paddingCells: 1.5
        )

        return TextRegionAnalysis(
            roiRegions: roiRegions,
            yodoMaskRegions: yodoRegions,
            roiCoverage: coverage(of: roiRegions, width: width, height: height),
            yodoMaskCoverage: coverage(of: yodoRegions, width: width, height: height)
        )
    }

    private static func isTextLikeCell(
        rect: CGRect,
        base: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        layout: PackedPixelLayout,
        width: Int,
        height: Int
    ) -> Bool {
        let minX = max(0, Int(rect.minX))
        let maxX = min(width - 2, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(height - 2, Int(rect.maxY))
        let step = max(1, min(maxX - minX, maxY - minY) / 8)
        var edgeCount = 0
        var samples = 0
        var minLum = 255
        var maxLum = 0

        for y in stride(from: minY, to: maxY, by: step) {
            for x in stride(from: minX, to: maxX, by: step) {
                let lum = Int(layout.luminance(base: base, bytesPerRow: bytesPerRow, x: x, y: y))
                let right = Int(layout.luminance(base: base, bytesPerRow: bytesPerRow, x: x + 1, y: y))
                let down = Int(layout.luminance(base: base, bytesPerRow: bytesPerRow, x: x, y: y + 1))
                if abs(lum - right) > edgeThreshold || abs(lum - down) > edgeThreshold {
                    edgeCount += 1
                }
                minLum = min(minLum, lum)
                maxLum = max(maxLum, lum)
                samples += 1
            }
        }

        guard samples > 0 else { return false }
        let edgeDensity = Double(edgeCount) / Double(samples)
        let contrast = maxLum - minLum
        return contrast >= minContrast
            && edgeDensity >= minEdgeDensity
            && edgeDensity <= maxEdgeDensity
    }

    private static func connectedClusters(cells: [Bool], columns: Int, rows: Int) -> [[Int]] {
        var visited = Array(repeating: false, count: cells.count)
        var clusters: [[Int]] = []

        for index in cells.indices where cells[index] && !visited[index] {
            var cluster: [Int] = []
            var stack = [index]
            visited[index] = true

            while let current = stack.popLast() {
                cluster.append(current)
                let row = current / columns
                let column = current % columns
                for deltaRow in -1...1 {
                    for deltaColumn in -1...1 {
                        guard deltaRow != 0 || deltaColumn != 0 else { continue }
                        let nextRow = row + deltaRow
                        let nextColumn = column + deltaColumn
                        guard nextRow >= 0, nextRow < rows, nextColumn >= 0, nextColumn < columns else { continue }
                        let next = nextRow * columns + nextColumn
                        if cells[next] && !visited[next] {
                            visited[next] = true
                            stack.append(next)
                        }
                    }
                }
            }

            if cluster.count >= minClusterCells {
                clusters.append(cluster)
            }
        }

        return clusters
    }

    private static func regions(
        from clusters: [[Int]],
        columns: Int,
        width: Int,
        height: Int,
        cellWidth: Int,
        cellHeight: Int,
        paddingCells: Double
    ) -> [TextRegion] {
        clusters
            .compactMap { cluster -> TextRegion? in
                let cellCount = cluster.count
                let columnsInCluster = cluster.map { $0 % columns }
                let rowsInCluster = cluster.map { $0 / columns }
                guard let minColumn = columnsInCluster.min(),
                      let maxColumn = columnsInCluster.max(),
                      let minRow = rowsInCluster.min(),
                      let maxRow = rowsInCluster.max() else { return nil }

                let padX = CGFloat(paddingCells) * CGFloat(cellWidth)
                let padY = CGFloat(paddingCells) * CGFloat(cellHeight)
                let rect = CGRect(
                    x: CGFloat(minColumn * cellWidth) - padX,
                    y: CGFloat(minRow * cellHeight) - padY,
                    width: CGFloat((maxColumn - minColumn + 1) * cellWidth) + padX * 2,
                    height: CGFloat((maxRow - minRow + 1) * cellHeight) + padY * 2
                ).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral

                guard rect.width >= 10, rect.height >= 8 else { return nil }
                let rectCoverage = Double(rect.width * rect.height) / Double(width * height)
                guard rectCoverage <= maxRegionCoverage else { return nil }
                let normalized = CGRect(
                    x: rect.minX / CGFloat(width),
                    y: rect.minY / CGFloat(height),
                    width: rect.width / CGFloat(width),
                    height: rect.height / CGFloat(height)
                )
                let area = max(1.0, Double(rect.width * rect.height))
                let textnessScore = Double(cellCount) / area
                return TextRegion(pixelRect: rect, normalizedRect: normalized, textnessScore: textnessScore)
            }
            .sorted { lhs, rhs in
                if lhs.textnessScore != rhs.textnessScore {
                    return lhs.textnessScore > rhs.textnessScore
                }
                return lhs.pixelRect.width * lhs.pixelRect.height < rhs.pixelRect.width * rhs.pixelRect.height
            }
            .prefix(maxRegions)
            .map { $0 }
    }

    private static func coverage(of regions: [TextRegion], width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return 0 }
        let totalArea = Double(width * height)
        let area = regions.reduce(0.0) { partial, region in
            partial + Double(region.pixelRect.width * region.pixelRect.height)
        }
        return min(1, area / totalArea)
    }
}
