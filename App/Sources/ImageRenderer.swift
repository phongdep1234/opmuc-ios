//
//  ImageRenderer.swift
//  Cắt ảnh theo khung ốp, chỉnh sáng/tương phản và chuyển về 4 màu mực.
//

import UIKit
import CoreImage

struct EditState: Equatable {
    var scale: CGFloat = 1
    /// Dịch chuyển, tính theo tỉ lệ khung (0.1 = 10% bề rộng/cao)
    var offset: CGSize = .zero
    var brightness: Double = 0
    var contrast: Double = 1.1
    var saturation: Double = 1.4
    var dither: Bool = true
    var bwOnly: Bool = false
}

enum ImageRenderer {
    /// 0 đen, 1 trắng, 2 vàng, 3 đỏ — màu dùng để tính lượng tử hoá
    static let quantColors: [(Float, Float, Float)] = [
        (0, 0, 0), (255, 255, 255), (255, 220, 0), (200, 20, 20)
    ]
    /// Màu hiển thị xem trước (gần màu mực thật)
    static let previewColors: [(UInt8, UInt8, UInt8)] = [
        (25, 25, 25), (238, 236, 228), (236, 190, 20), (178, 30, 30)
    ]

    private static let ciContext = CIContext(options: nil)

    /// Xoay đúng chiều ảnh và thu nhỏ để xử lý nhanh
    static func normalized(_ image: UIImage, maxSide: CGFloat = 1400) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let k = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * k).rounded()), height: max(1, (size.height * k).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let out = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return out.cgImage
    }

    static func adjusted(_ cg: CGImage, _ st: EditState) -> CGImage {
        let input = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIColorControls") else { return cg }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(st.brightness, forKey: kCIInputBrightnessKey)
        f.setValue(st.contrast, forKey: kCIInputContrastKey)
        f.setValue(st.saturation, forKey: kCIInputSaturationKey)
        guard let out = f.outputImage,
              let res = ciContext.createCGImage(out, from: input.extent) else { return cg }
        return res
    }

    /// Dựng ảnh w×h (dọc) thành mảng chỉ số màu
    static func indices(source: CGImage, w: Int, h: Int, state st: EditState, bwOnly: Bool) -> [UInt8] {
        let img = adjusted(source, st)
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let fw = CGFloat(w), fh = CGFloat(h)
            let s = max(fw / iw, fh / ih) * max(st.scale, 0.2)
            let dw = iw * s, dh = ih * s
            let cx = fw / 2 + st.offset.width * fw
            let cyDown = fh / 2 + st.offset.height * fh
            let x = cx - dw / 2
            let yDown = cyDown - dh / 2
            let yUp = fh - yDown - dh
            ctx.draw(img, in: CGRect(x: x, y: yUp, width: dw, height: dh))
        }
        return quantize(rgba: rgba, w: w, h: h, dither: st.dither, bwOnly: bwOnly || st.bwOnly)
    }

    static func quantize(rgba: [UInt8], w: Int, h: Int, dither: Bool, bwOnly: Bool) -> [UInt8] {
        let n = w * h
        var r = [Float](repeating: 0, count: n)
        var g = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            r[i] = Float(rgba[i * 4])
            g[i] = Float(rgba[i * 4 + 1])
            b[i] = Float(rgba[i * 4 + 2])
        }
        let allowed: [Int] = bwOnly ? [0, 1] : [0, 1, 2, 3]
        var out = [UInt8](repeating: 1, count: n)

        @inline(__always) func spread(_ j: Int, _ er: Float, _ eg: Float, _ eb: Float, _ k: Float) {
            r[j] += er * k; g[j] += eg * k; b[j] += eb * k
        }

        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let pr = min(max(r[i], 0), 255)
                let pg = min(max(g[i], 0), 255)
                let pb = min(max(b[i], 0), 255)
                var best = 1
                var bestD = Float.greatestFiniteMagnitude
                for c in allowed {
                    let q = quantColors[c]
                    let dr = pr - q.0, dg = pg - q.1, db = pb - q.2
                    let d = 3 * dr * dr + 4 * dg * dg + 2 * db * db
                    if d < bestD { bestD = d; best = c }
                }
                out[i] = UInt8(best)
                if dither {
                    let q = quantColors[best]
                    let er = pr - q.0, eg = pg - q.1, eb = pb - q.2
                    if x + 1 < w { spread(i + 1, er, eg, eb, 7.0 / 16) }
                    if y + 1 < h {
                        if x > 0 { spread(i + w - 1, er, eg, eb, 3.0 / 16) }
                        spread(i + w, er, eg, eb, 5.0 / 16)
                        if x + 1 < w { spread(i + w + 1, er, eg, eb, 1.0 / 16) }
                    }
                }
            }
        }
        return out
    }

    static func preview(_ idx: [UInt8], w: Int, h: Int) -> UIImage? {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let c = previewColors[Int(min(idx[i], 3))]
            px[i * 4] = c.0; px[i * 4 + 1] = c.1; px[i * 4 + 2] = c.2; px[i * 4 + 3] = 255
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Ảnh thử: trên trái đen, trên phải trắng, dưới trái vàng, dưới phải đỏ, có mũi tên chỉ lên ở giữa.
    static func testPattern(w: Int, h: Int, bwOnly: Bool) -> [UInt8] {
        var a = [UInt8](repeating: 1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let top = y < h / 2, left = x < w / 2
                var c: UInt8
                if top { c = left ? 0 : 1 } else { c = left ? 2 : 3 }
                if bwOnly && c >= 2 { c = (c == 2) ? 1 : 0 }
                a[y * w + x] = c
            }
        }
        // Mũi tên chỉ lên (viền đen, ruột trắng) trong dải giữa phía trên
        let cx = w / 2
        let tipY = h / 12
        let headH = w / 4
        for y in tipY..<(tipY + headH) {
            let half = (y - tipY) * (w / 5) / headH
            for x in (cx - half)...(cx + half) where x >= 0 && x < w {
                a[y * w + x] = (abs(x - cx) >= half - 4 || y >= tipY + headH - 5) ? 0 : 1
            }
        }
        let shaftEnd = max(tipY + headH, h / 2 - h / 20)
        for y in (tipY + headH)..<shaftEnd {
            for x in (cx - w / 16)...(cx + w / 16) {
                a[y * w + x] = (abs(x - cx) >= w / 16 - 4) ? 0 : 1
            }
        }
        return a
    }
}
