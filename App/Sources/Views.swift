//
//  Views.swift
//  Giao diện app "Ốp Mực".
//

import SwiftUI
import PhotosUI

@main
struct OpMucApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            PhotoView()
                .tabItem { Label("Ảnh", systemImage: "photo.on.rectangle") }
            CheckView()
                .tabItem { Label("Kiểm tra", systemImage: "antenna.radiowaves.left.and.right") }
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }
        }
    }
}

// MARK: - Tab Ảnh

struct PhotoView: View {
    @ObservedObject private var runner = NFCRunner.shared
    @AppStorage("colorMode") private var colorMode = "4"

    @State private var pickerItem: PhotosPickerItem?
    @State private var source: CGImage?
    @State private var edit = EditState()
    @State private var preview: UIImage?
    @State private var dragNow: CGSize = .zero
    @State private var pinchNow: CGFloat = 1
    @State private var rendering = false
    @State private var renderToken = 0

    @AppStorage("detW") private var detW = 0
    @AppStorage("detH") private var detH = 0

    private let frameW: CGFloat = 264
    private var pw: Int { EPaper.previewSize.w }
    private var ph: Int { EPaper.previewSize.h }
    private var frameH: CGFloat { frameW * CGFloat(ph) / CGFloat(pw) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    caseFrame
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(source == nil ? "Chọn ảnh" : "Chọn ảnh khác", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if source != nil { controls }

                    Button {
                        sendPhoto()
                    } label: {
                        Label("Gửi lên ốp", systemImage: "wave.3.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || runner.busy)

                    Button {
                        sendTestPattern()
                    } label: {
                        Label("Gửi ảnh thử 4 màu", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(runner.busy)

                    if !runner.message.isEmpty {
                        Text(runner.message)
                            .font(.callout)
                            .foregroundColor(runner.lastOK ? .green : .orange)
                            .multilineTextAlignment(.center)
                    }
                    Text("Ốp gắn sẵn trên iPhone, chỉ cần bấm Gửi rồi giữ yên máy đến khi xong.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Ốp Mực")
        }
        .navigationViewStyle(.stack)
        .onChange(of: pickerItem) { item in load(item) }
        .onChange(of: colorMode) { _ in rerender() }
        .onChange(of: detW) { _ in rerender() }
        .onChange(of: detH) { _ in rerender() }
    }

    private var caseFrame: some View {
        ZStack {
            Color(white: 0.93)
            if let p = preview {
                Image(uiImage: p)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: frameW, height: frameH)
                    .scaleEffect(pinchNow)
                    .offset(dragNow)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.largeTitle)
                    Text("Chọn ảnh để bắt đầu").font(.callout)
                }
                .foregroundColor(.secondary)
            }
            if rendering {
                ProgressView().padding(8).background(.ultraThinMaterial).cornerRadius(8)
            }
        }
        .frame(width: frameW, height: frameH)
        .clipped()
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(
            SimultaneousGesture(
                DragGesture()
                    .onChanged { v in dragNow = v.translation }
                    .onEnded { v in
                        edit.offset.width += v.translation.width / frameW
                        edit.offset.height += v.translation.height / frameH
                        dragNow = .zero
                        rerender()
                    },
                MagnificationGesture()
                    .onChanged { m in pinchNow = m }
                    .onEnded { m in
                        edit.scale = min(max(edit.scale * m, 0.3), 8)
                        pinchNow = 1
                        rerender()
                    }
            )
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kiểu", selection: $edit.dither) {
                Text("Ảnh chụp").tag(true)
                Text("Tranh / chữ").tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: edit.dither) { _ in rerender() }

            Toggle("Chỉ dùng đen trắng", isOn: $edit.bwOnly)
                .onChange(of: edit.bwOnly) { _ in rerender() }

            slider("Độ sáng", value: $edit.brightness, range: -0.4...0.4)
            slider("Tương phản", value: $edit.contrast, range: 0.5...2.0)
            slider("Độ đậm màu", value: $edit.saturation, range: 0...2.5)

            HStack {
                Button("Căn giữa lại") {
                    edit.scale = 1
                    edit.offset = .zero
                    rerender()
                }
                Spacer()
                Button("Đặt lại màu") {
                    let d = EditState()
                    edit.brightness = d.brightness
                    edit.contrast = d.contrast
                    edit.saturation = d.saturation
                    rerender()
                }
            }
            .font(.callout)
            Text("Kéo để dời ảnh, chụm hai ngón để phóng to/thu nhỏ.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Slider(value: value, in: range) { editing in
                if !editing { rerender() }
            }
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        rendering = true
        Task {
            var cg: CGImage?
            if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                cg = ImageRenderer.normalized(ui)
            }
            await MainActor.run {
                source = cg
                edit.scale = 1
                edit.offset = .zero
                rendering = false
                if cg == nil { runner.message = "Không mở được ảnh này." ; runner.lastOK = false }
                rerender()
            }
        }
    }

    private func rerender() {
        guard let src = source else { return }
        renderToken += 1
        let token = renderToken
        let st = edit
        let bw = colorMode == "2"
        let w = pw, h = ph
        rendering = true
        DispatchQueue.global(qos: .userInitiated).async {
            let idx = ImageRenderer.indices(source: src, w: w, h: h, state: st, bwOnly: bw)
            let img = ImageRenderer.preview(idx, w: w, h: h)
            DispatchQueue.main.async {
                guard token == renderToken else { return }
                preview = img
                rendering = false
            }
        }
    }

    private func sendPhoto() {
        guard let src = source else { return }
        let st = edit
        runner.run(.send(render: { spec in
            let (w, h) = spec.portraitSize
            return ImageRenderer.indices(source: src, w: w, h: h, state: st, bwOnly: spec.bpp == 1)
        }))
    }

    private func sendTestPattern() {
        runner.run(.send(render: { spec in
            let (w, h) = spec.portraitSize
            return ImageRenderer.testPattern(w: w, h: h, bwOnly: spec.bpp == 1)
        }))
    }
}

// MARK: - Tab Kiểm tra

struct CheckView: View {
    @ObservedObject private var runner = NFCRunner.shared
    @ObservedObject private var log = LogStore.shared
    @State private var rawText = "00 D1 00 00 00"
    @State private var rawError = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        runner.run(.detect)
                    } label: {
                        Label("Đọc thông tin ốp", systemImage: "magnifyingglass")
                    }
                    .disabled(runner.busy)
                    Button {
                        runner.run(.probe(EPaper.probeGroups))
                    } label: {
                        Label("Dò giao thức (khi gửi ảnh bị lỗi)", systemImage: "stethoscope")
                    }
                    .disabled(runner.busy)
                    Button {
                        runner.run(.scan(EPaper.scanCommands))
                    } label: {
                        Label("Quét lệnh của ốp", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(runner.busy)
                    if !runner.message.isEmpty {
                        Text(runner.message).font(.callout)
                            .foregroundColor(runner.lastOK ? .green : .orange)
                    }
                } footer: {
                    Text("Bấm để app nhận diện ốp và đọc kích thước màn hình.")
                }

                Section {
                    TextField("Lệnh APDU dạng hex, mỗi dòng một lệnh", text: $rawText, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .lineLimit(1...6)
                    Button("Gửi lệnh") { sendRaw() }
                        .disabled(runner.busy)
                    if !rawError.isEmpty {
                        Text(rawError).font(.caption).foregroundColor(.red)
                    }
                } header: {
                    Text("Lệnh thủ công (nâng cao)")
                }

                Section {
                    HStack {
                        Button("Sao chép") { UIPasteboard.general.string = log.text }
                        Spacer()
                        ShareLink(item: log.text) { Text("Chia sẻ") }
                        Spacer()
                        Button("Xoá", role: .destructive) { log.clear() }
                    }
                    .buttonStyle(.borderless)
                    if log.lines.isEmpty {
                        Text("Chưa có gì.").foregroundColor(.secondary)
                    } else {
                        Text(log.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Nhật ký")
                } footer: {
                    Text("Nếu ốp không nhận, sao chép nhật ký này gửi cho Claude để chỉnh app.")
                }
            }
            .navigationTitle("Kiểm tra ốp")
        }
        .navigationViewStyle(.stack)
    }

    private func sendRaw() {
        let lines = rawText.split(whereSeparator: { $0 == "\n" || $0 == ";" })
        var cmds: [Data] = []
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard let d = Data(hexString: t), d.count >= 4 else {
                rawError = "Dòng không hợp lệ: \(t)"
                return
            }
            cmds.append(d)
        }
        guard !cmds.isEmpty else { rawError = "Chưa nhập lệnh."; return }
        rawError = ""
        runner.run(.raw(cmds))
    }
}

// MARK: - Tab Cài đặt

struct SettingsView: View {
    @AppStorage("sizeMode") private var sizeMode = "auto"
    @AppStorage("colorMode") private var colorMode = "4"
    @AppStorage("swapWH") private var swapWH = false
    @AppStorage("rotate180") private var rotate180 = false
    @AppStorage("mirror") private var mirror = false
    @AppStorage("colorOrder") private var colorOrder = "BWYR"
    @AppStorage("reauthOnResume") private var reauthOnResume = false
    @AppStorage("compress") private var compress = true
    @AppStorage("fragmentSize") private var fragmentSize = 250
    @AppStorage("detW") private var detW = 0
    @AppStorage("detH") private var detH = 0

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Kích thước", selection: $sizeMode) {
                        Text("Tự động (đọc từ ốp)").tag("auto")
                        Text("240 × 416").tag("240x416")
                        Text("480 × 800").tag("480x800")
                        Text("800 × 480").tag("800x480")
                    }
                    Picker("Số màu", selection: $colorMode) {
                        Text("4 màu").tag("4")
                        Text("Đen trắng").tag("2")
                    }
                } header: {
                    Text("Màn hình ốp")
                } footer: {
                    Text(detW > 0 ? "Ốp đã nhận diện: \(detW)×\(detH). Để “Tự động” là đúng nhất." : "Để “Tự động”: app đọc kích thước từ ốp. Bấm “Đọc thông tin ốp” ở tab Kiểm tra trước.")
                }

                Section {
                    Toggle("Xoay 180°", isOn: $rotate180)
                    Toggle("Lật gương trái ↔ phải", isOn: $mirror)
                    Toggle("Đổi chiều bộ nhớ (ngang ↔ dọc)", isOn: $swapWH)
                    Picker("Thứ tự màu", selection: $colorOrder) {
                        Text("Đen–Trắng–Vàng–Đỏ").tag("BWYR")
                        Text("Đen–Trắng–Đỏ–Vàng").tag("BWRY")
                    }
                } header: {
                    Text("Sửa ảnh bị lệch")
                } footer: {
                    Text("Gửi “ảnh thử 4 màu”: đúng là trên-trái ĐEN, trên-phải TRẮNG, dưới-trái VÀNG, dưới-phải ĐỎ, mũi tên chỉ lên. Ảnh ngược thì bật Xoay 180°; ngược trái-phải thì bật Lật gương; ảnh ra sọc chéo/rác thì bật Đổi chiều bộ nhớ; vàng và đỏ đổi chỗ thì đổi Thứ tự màu.")
                }

                Section {
                    Toggle("Xác thực lại sau khi kết nối lại", isOn: $reauthOnResume)
                    Toggle("Nén dữ liệu (LZO)", isOn: $compress)
                    Picker("Cỡ mỗi gói", selection: $fragmentSize) {
                        Text("250 byte").tag(250)
                        Text("200 byte").tag(200)
                        Text("128 byte").tag(128)
                        Text("64 byte").tag(64)
                    }
                } header: {
                    Text("Nâng cao")
                } footer: {
                    Text("Chỉ đổi khi gửi ảnh bị lỗi. iOS chỉ cho mỗi lần kết nối NFC khoảng 20 giây, nên app tự kết nối lại giữa chừng.")
                }

                Section {
                    Text("Ốp Mực – app tự làm cho ốp lưng mực điện tử NFC.\nGiao thức dựa trên tài liệu mở của niw (MIT).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Cài đặt")
        }
        .navigationViewStyle(.stack)
    }
}
