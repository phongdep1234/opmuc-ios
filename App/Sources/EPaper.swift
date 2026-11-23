//
//  EPaper.swift
//  Giao thức NFC cho màn e-paper thụ động (họ Good Display / FMSC, ISO 14443-A + APDU ISO 7816).
//  Tham khảo: https://gist.github.com/niw/3885b22d502bb1e145984d41568f202d (MIT)
//

import Foundation

struct PanelSpec: CustomStringConvertible {
    /// Kích thước bộ nhớ ảnh của màn (số điểm mỗi hàng × số hàng)
    var width: Int
    var height: Int
    /// 1 = đen trắng, 2 = 4 màu
    var bpp: Int
    var name: String = ""
    var fromDevice: Bool = false

    var description: String {
        let colors = bpp == 2 ? "4 màu" : "đen trắng"
        let n = name.isEmpty ? "" : " – \(name)"
        return "\(width)×\(height), \(colors)\(n)"
    }

    /// Kích thước ảnh dựng theo chiều dọc của ốp
    var portraitSize: (w: Int, h: Int) { (min(width, height), max(width, height)) }

    var packedByteCount: Int { width * height * bpp / 8 }
}

/// Cài đặt người dùng (đọc từ UserDefaults, chỉnh trong tab Cài đặt)
struct TransferSettings {
    var sizeMode: String      // "auto", "480x800", "800x480"
    var colorMode: String     // "4", "2"
    var swapWH: Bool
    var rotate180: Bool
    var mirror: Bool
    var colorOrder: String    // "BWYR", "BWRY"
    var reauthOnResume: Bool
    var compress: Bool
    var fragmentSize: Int
    /// Thời gian chờ ốp nạp điện sau mỗi lần kết nối (ms)
    var prechargeMs: Int
    /// "msb": trái→phải, điểm đầu ở bit cao (FMSC); "lsb": phải→trái, điểm đầu ở bit thấp
    var bitOrder: String

    static var current: TransferSettings {
        let d = UserDefaults.standard
        return TransferSettings(
            sizeMode: d.string(forKey: "sizeMode") ?? "auto",
            colorMode: d.string(forKey: "colorMode") ?? "4",
            swapWH: d.bool(forKey: "swapWH"),
            rotate180: d.bool(forKey: "rotate180"),
            mirror: d.bool(forKey: "mirror"),
            colorOrder: d.string(forKey: "colorOrder") ?? "BWYR",
            reauthOnResume: d.object(forKey: "reauthOnResume") as? Bool ?? false,
            compress: d.object(forKey: "compress") as? Bool ?? true,
            fragmentSize: { let v = d.integer(forKey: "fragmentSize"); return v > 0 ? v : 250 }(),
            prechargeMs: d.object(forKey: "prechargeMs") as? Int ?? 2000,
            bitOrder: d.string(forKey: "bitOrder") ?? "msb"
        )
    }

    var manualSpec: PanelSpec {
        let bpp = colorMode == "2" ? 1 : 2
        switch sizeMode {
        case "800x480": return PanelSpec(width: 800, height: 480, bpp: bpp)
        case "480x800": return PanelSpec(width: 480, height: 800, bpp: bpp)
        case "240x416": return PanelSpec(width: 240, height: 416, bpp: bpp)
        default:
            // Thông số đã đọc từ ốp lần trước, mặc định 240×416 (màn 3,7 inch 4 màu)
            let d = UserDefaults.standard
            let w = d.integer(forKey: "detW"), h = d.integer(forKey: "detH")
            if w > 0 && h > 0 { return PanelSpec(width: w, height: h, bpp: bpp) }
            return PanelSpec(width: 240, height: 416, bpp: bpp)
        }
    }
}

enum EPaper {
    // MARK: Lệnh APDU
    static let selectAID = Data([0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00])
    static let auth = Data([0x00, 0x20, 0x00, 0x01, 0x04, 0x20, 0x09, 0x12, 0x10])
    /// Kiểm tra quyền truy cập (FMSC). 6985 = cần PIN
    static let access = Data([0xF0, 0xD8, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x0E])
    /// PIN mặc định của nhà máy FMSC
    static let pinAuth = Data([0x00, 0x20, 0x00, 0x01, 0x05, 0x52, 0x65, 0x69, 0x99, 0x19])
    static let wait = Data()
    static let deviceInfo = Data([0x00, 0xD1, 0x00, 0x00, 0x00])
    static let refreshBlocking = Data([0xF0, 0xD4, 0x85, 0x00, 0x00])
    static let refreshNonBlocking = Data([0xF0, 0xD4, 0x85, 0x80, 0x00])
    static let refreshStatus = Data([0xF0, 0xDE, 0x00, 0x00, 0x01])

    static let blockSize = 2000
    static let fragmentSize = 250

    // MARK: Thông tin thiết bị (TLV)
    static func tlv(_ data: Data) -> [UInt8: Data] {
        let b = [UInt8](data)
        var result: [UInt8: Data] = [:]
        var i = 0
        while i + 1 < b.count {
            let tag = b[i]
            let len = Int(b[i + 1])
            let start = i + 2
            let end = start + len
            if end > b.count { break }
            result[tag] = Data(b[start..<end])
            i = end
        }
        return result
    }

    static func parseInfo(_ data: Data) -> PanelSpec? {
        let t = tlv(data)
        guard let a0 = t[0xA0], a0.count >= 7 else { return nil }
        let b = [UInt8](a0)
        let colorByte = b[1]
        let bpp = (colorByte == 0x01 || colorByte == 0x47) ? 1 : 2
        let rh = (Int(b[3]) << 8) | Int(b[4])
        let rw = (Int(b[5]) << 8) | Int(b[6])
        let h = rh / bpp
        guard rw >= 16, h >= 16, rw <= 2000, h <= 2000, rw % (8 / bpp) == 0 else { return nil }
        var spec = PanelSpec(width: rw, height: h, bpp: bpp, fromDevice: true)
        if let c0 = t[0xC0], let name = String(data: c0, encoding: .ascii) {
            spec.name = name.trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        }
        return spec
    }

    // MARK: Ảnh → bộ nhớ màn
    /// `portrait`: chỉ số màu (0 đen, 1 trắng, 2 vàng, 3 đỏ) kích thước pw×ph theo chiều dọc ốp.
    static func buffer(portrait src: [UInt8], pw: Int, ph: Int, spec: PanelSpec, settings s: TransferSettings) -> [UInt8] {
        // 1) Xoay 180° / lật gương theo cài đặt
        var img = src
        if s.rotate180 || s.mirror {
            var out = [UInt8](repeating: 1, count: pw * ph)
            for y in 0..<ph {
                for x in 0..<pw {
                    var sx = x, sy = y
                    if s.rotate180 { sx = pw - 1 - sx; sy = ph - 1 - sy }
                    if s.mirror { sx = pw - 1 - sx }
                    out[y * pw + x] = src[sy * pw + sx]
                }
            }
            img = out
        }

        // 2) Ghép vào bộ nhớ W×H
        let W = spec.width, H = spec.height
        var buf = [UInt8](repeating: 1, count: W * H)
        if W == pw && H == ph {
            buf = img
        } else if W == ph && H == pw {
            // Xoay 90° theo chiều kim đồng hồ
            for y in 0..<H {
                for x in 0..<W {
                    buf[y * W + x] = img[(ph - 1 - x) * pw + y]
                }
            }
        } else {
            // Kích thước lạ: co giãn gần nhất
            for y in 0..<H {
                for x in 0..<W {
                    let sx = min(pw - 1, x * pw / W)
                    let sy = min(ph - 1, y * ph / H)
                    buf[y * W + x] = img[sy * pw + sx]
                }
            }
        }

        // 3) Đổi chỉ số màu theo loại màn
        if spec.bpp == 1 {
            for i in buf.indices {
                switch buf[i] {
                case 0, 3: buf[i] = 0   // đen, đỏ → đen
                default: buf[i] = 1     // trắng, vàng → trắng
                }
            }
        } else if s.colorOrder == "BWRY" {
            for i in buf.indices {
                if buf[i] == 2 { buf[i] = 3 } else if buf[i] == 3 { buf[i] = 2 }
            }
        }
        return buf
    }

    /// Đóng gói: mỗi hàng ghi từ phải sang trái, điểm đầu ở bit thấp.
    static func pack(_ buf: [UInt8], width: Int, height: Int, bpp: Int, order: String = "lsb") -> Data {
        let ppb = 8 / bpp
        if order == "msb" {
            let bytesPerLine = width / ppb
            var out = Data(capacity: bytesPerLine * height)
            let mask = UInt8((1 << bpp) - 1)
            for y in 0..<height {
                let row = y * width
                for k in 0..<bytesPerLine {
                    var byte: UInt8 = 0
                    for p in 0..<ppb {
                        byte = (byte << UInt8(bpp)) | (buf[row + k * ppb + p] & mask)
                    }
                    out.append(byte)
                }
            }
            return out
        }
        let bytesPerLine = width / ppb
        var out = Data(capacity: bytesPerLine * height)
        for y in 0..<height {
            let row = y * width
            for k in 0..<bytesPerLine {
                let x0 = (bytesPerLine - 1 - k) * ppb
                var byte: UInt8 = 0
                for p in 0..<ppb {
                    byte |= (buf[row + x0 + p] & UInt8((1 << bpp) - 1)) << UInt8(p * bpp)
                }
                out.append(byte)
            }
        }
        return out
    }

    /// Chia khối 2000 byte → nén LZO1X → mảnh 250 byte → lệnh F0 D3.
    static func dataAPDU(p1: UInt8 = 0, last: Bool = true, payload n: Int, fill: UInt8 = 0x55) -> Data {
        var d = Data([0xF0, 0xD3, p1, last ? 0x01 : 0x00, UInt8(n + 2), 0x00, 0x00])
        d.append(contentsOf: [UInt8](repeating: fill, count: n))
        return d
    }

    /// Bộ lệnh dò giao thức (không làm mới màn hình)
    static var probeGroups: [(String, [Data])] {
        let d8 = Data([0xF0, 0xD8, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x0C])
        let de = Data([0xF0, 0xDE, 0x00, 0x00, 0x01])
        var d2 = Data([0xF0, 0xD2, 0x00, 0x00, 0x10])
        d2.append(contentsOf: [UInt8](repeating: 0x55, count: 16))
        return [
            ("Chờ nạp 2 giây rồi lệnh trạng thái", [wait, de]),
            ("Chờ nạp rồi kiểm tra quyền F0 D8", [wait, access, de]),
            ("Chờ nạp, PIN nhà máy, rồi F0 D8", [wait, pinAuth, access]),
            ("Chờ nạp, quyền, gói thô F0 D2 16 byte", [wait, access, d2]),
            ("Chờ nạp, quyền, gói nén F0 D3 16 byte", [wait, access, dataAPDU(payload: 16)]),
            ("Lệnh trạng thái F0 DE", [Data([0xF0, 0xDE, 0x00, 0x00, 0x01])]),
            ("Gói ảnh 16 byte", [dataAPDU(payload: 16)]),
            ("Gói ảnh 64 byte", [dataAPDU(payload: 64)]),
            ("Gói ảnh 128 byte", [dataAPDU(payload: 128)]),
            ("Gói ảnh 200 byte", [dataAPDU(payload: 200)]),
            ("Cấu hình màn F0 D8 rồi gói 64 byte", [d8, dataAPDU(payload: 64)]),
            ("Gói ảnh 64 byte, P1=01", [dataAPDU(p1: 1, payload: 64)]),
            ("Lệnh lạ F0 D3 rỗng", [Data([0xF0, 0xD3, 0x00, 0x00, 0x02, 0x00, 0x00])]),
            ("Đọc thông tin lần nữa", [deviceInfo])
        ]
    }

    /// Quét lệnh: CLA 00 với mọi INS, và các CLA khác với INS D0–DF
    static var scanCommands: [Data] {
        var out: [Data] = []
        for ins in 0...255 {
            // Bỏ qua các lệnh ghi/xoá chuẩn có thể làm hỏng dữ liệu thẻ
            if [0x0E, 0xD6, 0xD8, 0xDA, 0xDC, 0xE0, 0xE4, 0xE6, 0xE8, 0x44, 0x24, 0x2C].contains(ins) { continue }
            out.append(Data([0x00, UInt8(ins), 0x00, 0x00]))
        }
        for cla in [0x80, 0x90, 0xA0, 0xB0, 0xF0] {
            for ins in 0xD0...0xDF {
                out.append(Data([UInt8(cla), UInt8(ins), 0x00, 0x00]))
            }
        }
        return out
    }

    static func saveDetected(_ spec: PanelSpec) {
        let d = UserDefaults.standard
        d.set(spec.width, forKey: "detW")
        d.set(spec.height, forKey: "detH")
        d.set(spec.bpp, forKey: "detBpp")
    }

    /// Kích thước ảnh dọc để xem trước (theo ốp đã nhận diện)
    static var previewSize: (w: Int, h: Int) {
        let d = UserDefaults.standard
        let w = d.integer(forKey: "detW"), h = d.integer(forKey: "detH")
        if w > 0 && h > 0 { return (min(w, h), max(w, h)) }
        return (240, 416)
    }

    /// F0 D2: gửi thô không nén, mỗi gói 250 byte (P1 = ô ảnh, P2 = số thứ tự gói). Nhóm 8 gói/khối.
    static func rawAPDUs(packed: Data, chunk: Int = 250) -> [[Data]] {
        let bytes = [UInt8](packed)
        var all: [Data] = []
        var off = 0
        var idx = 0
        while off < bytes.count {
            let end = min(off + chunk, bytes.count)
            var cmd = Data([0xF0, 0xD2, 0x00, UInt8(idx & 0xFF), UInt8(end - off)])
            cmd.append(contentsOf: bytes[off..<end])
            all.append(cmd)
            off = end
            idx += 1
        }
        return stride(from: 0, to: all.count, by: 8).map { Array(all[$0..<min($0 + 8, all.count)]) }
    }

    static func imageAPDUs(packed: Data, compress: Bool = true, fragmentSize: Int = 250) -> [[Data]] {
        let bytes = [UInt8](packed)
        var blocks: [[Data]] = []
        var blockIndex = 0
        var start = 0
        while start < bytes.count {
            let end = min(start + blockSize, bytes.count)
            let raw = Data(bytes[start..<end])
            let compressed = [UInt8](compress ? lzoCompress(raw) : raw)
            var frags: [Data] = []
            var fStart = 0
            var fIndex = 0
            while fStart < compressed.count {
                let fEnd = min(fStart + fragmentSize, compressed.count)
                let isLast = fEnd == compressed.count
                var cmd = Data([0xF0, 0xD3, 0x00, isLast ? 0x01 : 0x00, UInt8(fEnd - fStart + 2)])
                cmd.append(UInt8(blockIndex & 0xFF))
                cmd.append(UInt8(fIndex & 0xFF))
                cmd.append(contentsOf: compressed[fStart..<fEnd])
                frags.append(cmd)
                fStart = fEnd
                fIndex += 1
            }
            blocks.append(frags)
            blockIndex += 1
            start = end
        }
        return blocks
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    init?(hexString: String) {
        let chars = hexString.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var d = Data()
        var it = chars.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
            d.append(v)
        }
        self = d
    }
}
