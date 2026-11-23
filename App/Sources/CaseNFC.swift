//
//  CaseNFC.swift
//  Phiên NFC với ốp lưng mực điện tử.
//

import Foundation
import CoreNFC

enum NFCJob {
    case detect
    /// Nhận thông số màn, trả về ảnh dọc (chỉ số màu) đúng kích thước `spec.portraitSize`
    case send(render: (PanelSpec) -> [UInt8])
    case raw([Data])
    /// Các nhóm lệnh thử; mỗi nhóm chạy trong một lần kết nối, lỗi thì sang nhóm sau
    case probe([(String, [Data])])
    /// Quét nhiều lệnh, mỗi lệnh một dòng nhật ký
    case scan([Data])
}

enum CaseError: LocalizedError {
    case badAPDU
    case status(String, UInt8, UInt8)
    case unsupportedTag(String)
    case differentTag

    var errorDescription: String? {
        switch self {
        case .badAPDU: return "Lệnh APDU không hợp lệ"
        case let .status(label, a, b): return String(format: "%@ bị ốp từ chối (mã %02X%02X)", label, a, b)
        case let .unsupportedTag(t): return "Ốp dùng chuẩn NFC \(t) – chưa hỗ trợ"
        case .differentTag: return "Phát hiện thẻ NFC khác ốp"
        }
    }
}

enum TagLink {
    case iso7816(NFCISO7816Tag)
    case mifare(NFCMiFareTag)

    var isMifare: Bool { if case .mifare = self { return true } else { return false } }

    func send(_ bytes: Data) async throws -> (Data, UInt8, UInt8) {
        guard let apdu = NFCISO7816APDU(data: bytes) else { throw CaseError.badAPDU }
        switch self {
        case .iso7816(let t): return try await t.sendCommand(apdu: apdu)
        case .mifare(let t): return try await t.sendMiFareISO7816Command(apdu)
        }
    }
}

struct APDUResponse {
    var data: Data
    var sw1: UInt8
    var sw2: UInt8
    var ok: Bool { sw1 == 0x90 && sw2 == 0x00 }
    var sw: String { String(format: "%02X%02X", sw1, sw2) }
}

final class CaseNFC: NSObject, NFCTagReaderSessionDelegate {
    /// Giữ tham chiếu khi phiên đang chạy
    private static var current: CaseNFC?

    private let job: NFCJob
    private let settings: TransferSettings
    private let onFinish: (Bool, String) -> Void
    private let log = LogStore.shared
    private let queue = DispatchQueue(label: "opmuc.nfc")

    private var session: NFCTagReaderSession?
    private var finished = false
    private var connectedAt = Date()
    private var startedAt = Date()
    private var tagID: Data?

    // Trạng thái gửi ảnh (giữ qua các lần kết nối lại)
    private var blocks: [[Data]]?
    private var nextBlock = 0
    private var totalFragments = 0
    private var sentFragments = 0
    private var reconnects = 0

    /// Giới hạn ~20 giây của iOS cho mỗi lần kết nối
    private let connectBudget: TimeInterval = 15

    init(job: NFCJob, settings: TransferSettings, onFinish: @escaping (Bool, String) -> Void) {
        self.job = job
        self.settings = settings
        self.onFinish = onFinish
    }

    func start() {
        guard NFCTagReaderSession.readingAvailable else {
            onFinish(false, "Không dùng được NFC. Máy không hỗ trợ, hoặc lúc ký IPA chứng chỉ chưa bật quyền “NFC Tag Reading”.")
            return
        }
        guard let s = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: queue) else {
            onFinish(false, "Không mở được phiên NFC.")
            return
        }
        CaseNFC.current = self
        session = s
        startedAt = Date()
        s.alertMessage = "Giữ yên điện thoại – ốp đang gắn trên máy là được."
        log.add("— Bắt đầu phiên NFC —")
        s.begin()
    }

    // MARK: - Delegate

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if finished {
            CaseNFC.current = nil
            return
        }
        finished = true
        var msg = error.localizedDescription
        if let e = error as? NFCReaderError {
            switch e.code {
            case .readerSessionInvalidationErrorUserCanceled:
                msg = "Đã huỷ."
            case .readerSessionInvalidationErrorSessionTimeout:
                msg = "Hết thời gian 60 giây của iOS. Thử lại, giữ máy thật yên."
            case .readerErrorUnsupportedFeature:
                msg = "Máy không hỗ trợ đọc thẻ NFC."
            case .readerErrorSecurityViolation, .readerErrorInvalidParameter:
                msg = "App thiếu quyền NFC (chứng chỉ ký chưa bật NFC Tag Reading). Chi tiết: \(e.localizedDescription)"
            default: break
            }
        }
        log.add("Phiên kết thúc: \(error.localizedDescription)")
        let cb = onFinish
        DispatchQueue.main.async {
            cb(false, msg)
            CaseNFC.current = nil
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        if tags.count > 1 {
            log.add("Thấy \(tags.count) thẻ NFC, dùng thẻ đầu tiên")
        }
        Task { await self.handle(tag: tag, session: session) }
    }

    // MARK: - Xử lý

    private func handle(tag: NFCTag, session: NFCTagReaderSession) async {
        let link: TagLink
        let uid: Data
        switch tag {
        case .iso7816(let t):
            link = .iso7816(t)
            uid = t.identifier
            if tagID == nil {
                log.add("Loại thẻ: ISO 7816 (ISO 14443-4)")
                log.add("UID: \(t.identifier.hex)")
                log.add("AID đã chọn: \(t.initialSelectedAID)")
                if let hb = t.historicalBytes { log.add("Historical bytes: \(hb.hex)") }
                if let ad = t.applicationData { log.add("Application data: \(ad.hex)") }
            }
        case .miFare(let t):
            link = .mifare(t)
            uid = t.identifier
            if tagID == nil {
                log.add("Loại thẻ: MIFARE/ISO 14443-A, họ \(familyName(t.mifareFamily))")
                log.add("UID: \(t.identifier.hex)")
                if let hb = t.historicalBytes { log.add("Historical bytes: \(hb.hex)") }
            }
        case .iso15693(let t):
            log.add("Loại thẻ: ISO 15693, UID \(t.identifier.hex), hãng chip \(t.icManufacturerCode), serial \(t.icSerialNumber.hex)")
            fail(session, CaseError.unsupportedTag("ISO 15693"))
            return
        case .feliCa(let t):
            log.add("Loại thẻ: FeliCa, IDm \(t.currentIDm.hex)")
            fail(session, CaseError.unsupportedTag("FeliCa"))
            return
        @unknown default:
            fail(session, CaseError.unsupportedTag("lạ"))
            return
        }

        if let old = tagID, old != uid {
            log.add("UID khác lần trước: \(uid.hex)")
            fail(session, CaseError.differentTag)
            return
        }
        let resuming = tagID != nil
        tagID = uid

        do {
            try await session.connect(to: tag)
            connectedAt = Date()
            if resuming { log.add("Đã kết nối lại (lần \(reconnects))") }
            switch job {
            case .detect:
                try await runDetect(link, session)
            case .send(let render):
                try await runSend(link, session, render: render, resuming: resuming)
            case .raw(let cmds):
                try await runRaw(link, session, cmds)
            case .probe(let groups):
                await runProbe(link, session, groups)
            case .scan(let cmds):
                await runScan(link, session, cmds)
            }
        } catch {
            log.add("Lỗi: \(error.localizedDescription)")
            fail(session, error)
        }
    }

    @discardableResult
    private func tx(_ link: TagLink, _ cmd: Data, _ label: String, quiet: Bool = false, mustSucceed: Bool = true) async throws -> APDUResponse {
        if !quiet { log.add("→ \(label): \(cmd.hex)") }
        let (data, a, b) = try await link.send(cmd)
        let r = APDUResponse(data: data, sw1: a, sw2: b)
        if !quiet || !r.ok {
            log.add("← \(label): SW \(r.sw)\(data.isEmpty ? "" : " | \(data.hex)")")
        }
        if mustSucceed && !r.ok { throw CaseError.status(label, a, b) }
        return r
    }

    private func runDetect(_ link: TagLink, _ session: NFCTagReaderSession) async throws {
        if link.isMifare {
            try await tx(link, EPaper.selectAID, "Chọn ứng dụng", mustSucceed: false)
        }
        try await tx(link, EPaper.auth, "Xác thực", mustSucceed: false)
        let info = try await tx(link, EPaper.deviceInfo, "Đọc thông tin", mustSucceed: false)
        if info.ok, let spec = EPaper.parseInfo(info.data) {
            EPaper.saveDetected(spec)
            log.add("Màn hình ốp: \(spec)")
            succeed(session, "Nhận ra ốp: \(spec). Có thể gửi ảnh.")
        } else if info.ok {
            succeed(session, "Ốp có trả lời nhưng chưa hiểu thông tin. Gửi nhật ký để mình xem.")
        } else {
            succeed(session, "Ốp không theo giao thức quen thuộc (mã \(info.sw)). Sao chép nhật ký gửi mình nhé.")
        }
    }

    private var probeIndex = 0
    private var scanSummary: [String: [String]] = [:]

    private func runScan(_ link: TagLink, _ session: NFCTagReaderSession, _ cmds: [Data]) async {
        while probeIndex < cmds.count {
            let c = cmds[probeIndex]
            probeIndex += 1
            if probeIndex % 16 == 0 {
                session.alertMessage = "Đang quét \(probeIndex)/\(cmds.count)… giữ yên máy"
            }
            let key = String(format: "%02X %02X", c[0], c[1])
            do {
                let (data, a, b) = try await link.send(c)
                let sw = String(format: "%02X%02X", a, b)
                if sw == "6D00" || sw == "6E00" || sw == "6A81" || sw == "6986" {
                    scanSummary[sw, default: []].append(key)
                } else {
                    log.add("★ \(c.hex) → SW \(sw)\(data.isEmpty ? "" : " | \(data.prefix(40).hex)")")
                }
            } catch {
                scanSummary["lỗi", default: []].append(key)
                if probeIndex < cmds.count {
                    reconnects += 1
                    session.restartPolling()
                    return
                }
            }
        }
        for (sw, keys) in scanSummary.sorted(by: { $0.key < $1.key }) {
            log.add("SW \(sw) (\(keys.count) lệnh): \(keys.joined(separator: ", "))")
        }
        succeed(session, "Quét xong. Bấm Sao chép nhật ký gửi cho Claude.")
    }

    private func runProbe(_ link: TagLink, _ session: NFCTagReaderSession, _ groups: [(String, [Data])]) async {
        while probeIndex < groups.count {
            let (name, cmds) = groups[probeIndex]
            probeIndex += 1
            session.alertMessage = "Đang dò \(probeIndex)/\(groups.count)… giữ yên máy"
            log.add("=== Thử \(probeIndex): \(name) ===")
            do {
                for (i, c) in cmds.enumerated() {
                    if c.isEmpty {
                        log.add("… chờ nạp điện \(settings.prechargeMs) ms")
                        try? await Task.sleep(nanoseconds: UInt64(max(settings.prechargeMs, 500)) * 1_000_000)
                        continue
                    }
                    let shown = c.count > 24 ? "\(c.prefix(12).hex) … (\(c.count) byte)" : c.hex
                    log.add("→ \(shown)")
                    let r = try await tx(link, c, "Lệnh \(i + 1)", quiet: true, mustSucceed: false)
                    log.add("← SW \(r.sw)\(r.data.isEmpty ? "" : " | \(r.data.hex)")")
                }
            } catch {
                log.add("✗ Không trả lời: \(error.localizedDescription)")
                if probeIndex < groups.count {
                    reconnects += 1
                    session.restartPolling()
                    return
                }
            }
        }
        succeed(session, "Dò xong. Bấm Sao chép nhật ký gửi cho Claude.")
    }

    private func runRaw(_ link: TagLink, _ session: NFCTagReaderSession, _ cmds: [Data]) async throws {
        if link.isMifare {
            try await tx(link, EPaper.selectAID, "Chọn ứng dụng", mustSucceed: false)
        }
        for (i, c) in cmds.enumerated() {
            try await tx(link, c, "Lệnh \(i + 1)", mustSucceed: false)
        }
        succeed(session, "Đã gửi \(cmds.count) lệnh. Xem kết quả trong nhật ký.")
    }

    /// Chờ ốp nạp điện rồi xin quyền (F0 D8, cần thì PIN)
    private func powerUpAndAccess(_ link: TagLink, _ session: NFCTagReaderSession) async throws {
        session.alertMessage = "Đang nạp điện cho ốp… giữ yên máy"
        log.add("… chờ nạp điện \(settings.prechargeMs) ms")
        try? await Task.sleep(nanoseconds: UInt64(max(settings.prechargeMs, 0)) * 1_000_000)
        let a = try await tx(link, EPaper.access, "Kiểm tra quyền", mustSucceed: false)
        if a.ok { return }
        if a.sw1 == 0x69 && a.sw2 == 0x85 {
            let p = try await tx(link, EPaper.pinAuth, "PIN nhà máy", mustSucceed: false)
            if !p.ok { log.add("PIN bị từ chối, vẫn thử tiếp…") }
            try await tx(link, EPaper.access, "Kiểm tra quyền lần 2", mustSucceed: false)
        } else {
            log.add("Kiểm tra quyền trả \(a.sw), vẫn thử tiếp…")
        }
    }

    private var refreshPending = false

    private func runSend(_ link: TagLink, _ session: NFCTagReaderSession, render: (PanelSpec) -> [UInt8], resuming: Bool) async throws {
        if link.isMifare {
            try await tx(link, EPaper.selectAID, "Chọn ứng dụng", mustSucceed: false)
        }
        if !resuming {
            var spec = settings.manualSpec
            if settings.sizeMode == "auto" {
                let info = try await tx(link, EPaper.deviceInfo, "Đọc thông tin", mustSucceed: false)
                if info.ok, let s = EPaper.parseInfo(info.data) {
                    spec = s
                    EPaper.saveDetected(s)
                } else {
                    log.add("Không đọc được thông số, dùng mặc định \(spec)")
                }
            }
            if settings.colorMode == "2" { spec.bpp = 1 }
            if settings.swapWH { swap(&spec.width, &spec.height) }
            log.add("Dùng thông số: \(spec)")

            let (pw, ph) = spec.portraitSize
            let portrait = render(spec)
            guard portrait.count == pw * ph else { throw CaseError.badAPDU }
            let buf = EPaper.buffer(portrait: portrait, pw: pw, ph: ph, spec: spec, settings: settings)
            let packed = EPaper.pack(buf, width: spec.width, height: spec.height, bpp: spec.bpp, order: settings.bitOrder)
            let b = settings.compress
                ? EPaper.imageAPDUs(packed: packed, compress: true, fragmentSize: settings.fragmentSize)
                : EPaper.rawAPDUs(packed: packed, chunk: settings.fragmentSize)
            blocks = b
            totalFragments = b.reduce(0) { $0 + $1.count }
            log.add("Dữ liệu \(packed.count) byte → \(totalFragments) lệnh (\(settings.compress ? "F0 D3 nén" : "F0 D2 thô"), gói \(settings.fragmentSize) byte, bit \(settings.bitOrder))")
        }

        try await powerUpAndAccess(link, session)
        guard let blocks else { throw CaseError.badAPDU }

        while nextBlock < blocks.count {
            if Date().timeIntervalSince(connectedAt) > connectBudget {
                reconnect(session)
                return
            }
            for (fi, frag) in blocks[nextBlock].enumerated() {
                let label = "Khối \(nextBlock + 1)/\(blocks.count) gói \(fi + 1)"
                if sentFragments < 3 {
                    log.add("→ \(label): \(frag.prefix(16).hex) … (\(frag.count) byte)")
                }
                do {
                    try await sendWithRetry(link, frag, label)
                } catch {
                    log.add("✗ \(label) lỗi: \(error.localizedDescription)")
                    throw error
                }
                if sentFragments < 3 { log.add("← \(label): OK") }
                sentFragments += 1
            }
            nextBlock += 1
            let pct = Int(Double(sentFragments) / Double(max(totalFragments, 1)) * 100)
            session.alertMessage = "Đang gửi ảnh… \(pct)%"
        }
        log.add(String(format: "Gửi xong dữ liệu sau %.1f giây", Date().timeIntervalSince(startedAt)))

        // Làm mới trên một lần kết nối mới để có đủ thời gian
        if !refreshPending && Date().timeIntervalSince(connectedAt) > 2 + Double(settings.prechargeMs) / 1000 {
            refreshPending = true
            reconnect(session)
            return
        }

        session.alertMessage = "Đang làm mới màn hình ốp (20–40 giây)… giữ yên máy"
        let t0 = Date()
        let r = try await tx(link, EPaper.refreshBlocking, "Làm mới màn hình", mustSucceed: false)
        log.add(String(format: "Lệnh làm mới trả lời sau %.1f giây", Date().timeIntervalSince(t0)))
        if !r.ok {
            log.add("Làm mới kiểu chờ bị từ chối, thử kiểu không chờ…")
            let r2 = try await tx(link, EPaper.refreshNonBlocking, "Làm mới (không chờ)", mustSucceed: false)
            if !r2.ok { throw CaseError.status("Làm mới màn hình", r2.sw1, r2.sw2) }
        }
        // Theo dõi trạng thái nếu còn thời gian
        var busySeen = false
        while Date().timeIntervalSince(connectedAt) < 18 {
            let st = try await tx(link, EPaper.refreshStatus, "Trạng thái", quiet: true, mustSucceed: false)
            if st.data.first == 0x01 { busySeen = true } else { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log.add("Trạng thái sau làm mới: \(busySeen ? "đã thấy bận rồi rảnh" : "rảnh")")
        log.add(String(format: "Hoàn tất sau %.1f giây", Date().timeIntervalSince(startedAt)))
        succeed(session, "Xong! Ảnh đã lên ốp.")
    }

    /// Gửi một mảnh; nếu bị từ chối vì chưa xác thực (69 82) thì xác thực rồi thử lại một lần.
    private func sendWithRetry(_ link: TagLink, _ frag: Data, _ label: String) async throws {
        let r = try await tx(link, frag, label, quiet: true, mustSucceed: false)
        if r.ok { return }
        if r.sw1 == 0x69 {
            try await tx(link, EPaper.access, "Kiểm tra quyền lại", mustSucceed: false)
            try await tx(link, frag, label + " (thử lại)", quiet: true, mustSucceed: true)
            return
        }
        throw CaseError.status(label, r.sw1, r.sw2)
    }

    private func reconnect(_ session: NFCTagReaderSession) {
        reconnects += 1
        log.add("Sắp chạm giới hạn 20 giây của iOS → kết nối lại")
        session.alertMessage = "Đang kết nối lại… giữ yên máy"
        session.restartPolling()
    }

    private func succeed(_ session: NFCTagReaderSession, _ msg: String) {
        guard !finished else { return }
        finished = true
        log.add("✓ \(msg)")
        session.alertMessage = msg
        session.invalidate()
        let cb = onFinish
        DispatchQueue.main.async { cb(true, msg) }
    }

    private func fail(_ session: NFCTagReaderSession, _ error: Error) {
        guard !finished else { return }
        finished = true
        let msg = error.localizedDescription
        session.invalidate(errorMessage: msg)
        let cb = onFinish
        DispatchQueue.main.async {
            cb(false, msg)
            CaseNFC.current = nil
        }
    }

    private func familyName(_ f: NFCMiFareFamily) -> String {
        switch f {
        case .ultralight: return "Ultralight"
        case .plus: return "Plus"
        case .desfire: return "DESFire"
        case .unknown: return "ISO 14443-4"
        @unknown default: return "khác"
        }
    }
}

/// Nhật ký dùng chung để gỡ lỗi
final class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published private(set) var lines: [String] = []
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func add(_ s: String) {
        let line = "[\(fmt.string(from: Date()))] \(s)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 600 { self.lines.removeFirst(self.lines.count - 600) }
        }
    }

    func clear() { DispatchQueue.main.async { self.lines.removeAll() } }

    var text: String { lines.joined(separator: "\n") }
}

/// Điều phối một phiên NFC tại một thời điểm cho giao diện
final class NFCRunner: ObservableObject {
    static let shared = NFCRunner()
    @Published var busy = false
    @Published var message = ""
    @Published var lastOK = true

    func run(_ job: NFCJob) {
        guard !busy else { return }
        busy = true
        message = ""
        let c = CaseNFC(job: job, settings: .current) { [weak self] ok, msg in
            self?.busy = false
            self?.lastOK = ok
            self?.message = msg
        }
        c.start()
    }
}
