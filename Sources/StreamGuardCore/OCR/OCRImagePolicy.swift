import Foundation

/// Rules for when YODO / ROI crops are downscaled before Vision OCR.
public enum OCRImagePolicy {
    /// Returns an extra downscale factor (1 = original crop, 2 = half resolution).
    /// Small or text-dense crops (e.g. terminal panes) stay at 1× so digits stay readable.
    public static func adaptiveCropDownscaleFactor(cropWidth: Int, cropHeight: Int) -> CGFloat {
        let longEdge = max(cropWidth, cropHeight)
        let shortEdge = min(cropWidth, cropHeight)
        guard longEdge >= 900, shortEdge >= 220 else { return 1 }
        return 2
    }
}
