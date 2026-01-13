import SwiftUI
import ImageIO
import AppKit
import Foundation

// MARK: - 1. 数据模型
enum CullStatus: String {
    case none
    case winner // 绿 (King)
    case loser  // 黄 (Prince)
    case reject // 红 (Trash)
    
    var color: Color {
        switch self {
        case .none: return Color.gray.opacity(0.3)
        case .winner: return Color(red: 0.30, green: 0.85, blue: 0.39) // Green
        case .loser: return Color(red: 1.0, green: 0.8, blue: 0.0)     // Yellow
        case .reject: return Color(red: 1.0, green: 0.23, blue: 0.19)  // Red
        }
    }
}

class PhotoItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let filename: String
    @Published var status: CullStatus = .none
    @Published var thumbnail: NSImage?
    
    init(url: URL, filename: String, status: CullStatus = .none) {
        self.url = url
        self.filename = filename
        self.status = status
    }
}

class Arena: Identifiable, ObservableObject {
    let id = UUID()
    @Published var king: PhotoItem?
    @Published var princes: [PhotoItem] = []
    var isArchived: Bool = false
}

// MARK: - 2. 核心逻辑 ViewModel
class CullViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var selectionIndex: Int = 0
    @Published var currentImage: NSImage?
    @Published var compareImage: NSImage?
    
    @Published var arenas: [Arena] = [Arena()]
    var activeArena: Arena { arenas.last ?? Arena() }
    
    @Published var isLoading: Bool = false
    @Published var loadProgress: Double = 0.0
    @Published var loadingMessage: String = ""
    @Published var isComparing: Bool = false
    
    let allowedExtensions = ["ARW", "CR2", "CR3", "NEF", "DNG", "RAF", "JPG", "JPEG", "PNG"]
    
    // 打开文件夹
    func loadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择照片文件夹"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                startLoading(at: url)
            }
        }
    }
    
    // 预加载逻辑
    private func startLoading(at url: URL) {
        isLoading = true
        loadProgress = 0.0
        loadingMessage = "正在扫描文件..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fileManager = FileManager.default
                let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.tagNamesKey])
                
                let rawFiles = files.filter { self.allowedExtensions.contains($0.pathExtension.uppercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                
                let total = Double(rawFiles.count)
                var loadedItems: [PhotoItem] = []
                
                for (index, fileUrl) in rawFiles.enumerated() {
                    // 读取 Finder 标签
                    var status: CullStatus = .none
                    if let resources = try? fileUrl.resourceValues(forKeys: [.tagNamesKey]),
                       let tags = resources.tagNames {
                        if tags.contains("Green") { status = .winner }
                        else if tags.contains("Yellow") { status = .loser }
                        else if tags.contains("Red") { status = .reject }
                    }
                    
                    let item = PhotoItem(url: fileUrl, filename: fileUrl.lastPathComponent, status: status)
                    // 预生成小图
                    item.thumbnail = self.generateThumbnail(from: fileUrl, size: 150)
                    loadedItems.append(item)
                    
                    DispatchQueue.main.async {
                        self.loadProgress = Double(index + 1) / total
                        self.loadingMessage = "预加载: \(index + 1)/\(Int(total))"
                    }
                }
                
                DispatchQueue.main.async {
                    self.photos = loadedItems
                    self.selectionIndex = 0
                    self.arenas = [Arena()]
                    self.isLoading = false
                    if !self.photos.isEmpty { self.loadMainPreview() }
                }
            } catch {
                DispatchQueue.main.async { self.isLoading = false }
            }
        }
    }
    
    func generateThumbnail(from url: URL, size: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    func loadMainPreview() {
        guard !photos.isEmpty, selectionIndex < photos.count else { return }
        let url = photos[selectionIndex].url
        
        DispatchQueue.global(qos: .userInteractive).async {
            if let nsImage = self.generateThumbnail(from: url, size: 1800) {
                DispatchQueue.main.async { self.currentImage = nsImage }
            }
        }
        
        if let king = activeArena.king {
            DispatchQueue.global(qos: .userInteractive).async {
                if let kingImg = self.generateThumbnail(from: king.url, size: 1800) {
                    DispatchQueue.main.async { self.compareImage = kingImg }
                }
            }
        } else {
            compareImage = nil
        }
    }
    
    // --- 核心操作：Finder 标签写入 (终极修复版) ---
    func setFinderTag(for item: PhotoItem, tag: String?) {
        let fileUrl = item.url
        let nsUrl = fileUrl as NSURL // 强制转为 NSURL，绕过 Swift 的 get-only 限制
        let tags: [String] = tag != nil ? [tag!] : []
        
        do {
            // 使用 Objective-C 风格的 setResourceValue，绝对兼容
            try nsUrl.setResourceValue(tags, forKey: .tagNamesKey)
        } catch {
            print("Tag Error: \(error)")
        }
    }
    
    func triggerChallenge() {
        guard !photos.isEmpty else { return }
        let challenger = photos[selectionIndex]
        
        challenger.status = .winner
        setFinderTag(for: challenger, tag: "Green")
        
        let arena = activeArena
        if let oldKing = arena.king, oldKing.id != challenger.id {
            oldKing.status = .loser
            setFinderTag(for: oldKing, tag: "Yellow")
            arena.princes.insert(oldKing, at: 0)
        }
        
        arena.king = challenger
        objectWillChange.send()
        loadMainPreview()
    }
    
    func triggerFinalize() {
        guard !photos.isEmpty else { return }
        let currentPhoto = photos[selectionIndex]
        
        activeArena.isArchived = true
        let newArena = Arena()
        arenas.append(newArena)
        
        currentPhoto.status = .winner
        setFinderTag(for: currentPhoto, tag: "Green")
        newArena.king = currentPhoto
        
        objectWillChange.send()
        loadMainPreview()
    }
    
    func triggerReject() {
        guard !photos.isEmpty else { return }
        let item = photos[selectionIndex]
        item.status = .reject
        setFinderTag(for: item, tag: "Red")
        nextPhoto()
    }
    
    func nextPhoto() {
        if selectionIndex < photos.count - 1 {
            selectionIndex += 1
            loadMainPreview()
        }
    }
    
    func prevPhoto() {
        if selectionIndex > 0 {
            selectionIndex -= 1
            loadMainPreview()
        }
    }
    
    func setComparing(_ comparing: Bool) {
        if isComparing != comparing { isComparing = comparing }
    }
}

// MARK: - 3. UI 界面
struct ContentView: View {
    @StateObject var vm = CullViewModel()
    
    var body: some View {
        ZStack {
            HSplitView {
                SidebarView(vm: vm)
                    .frame(minWidth: 250, maxWidth: 300)
                StageView(vm: vm)
                    .frame(minWidth: 500)
                ArenaView(vm: vm)
                    .frame(minWidth: 220, maxWidth: 280)
            }
            
            if vm.isLoading {
                ZStack {
                    Color.black.opacity(0.8)
                    VStack(spacing: 20) {
                        ProgressView(value: vm.loadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                            .frame(width: 300)
                        Text(vm.loadingMessage).font(.headline).foregroundColor(.white)
                    }
                }
                .edgesIgnoringSafeArea(.all)
            }
        }
        .background(KeyMonitor(vm: vm))
        .frame(minWidth: 1000, minHeight: 700)
    }
}

struct SidebarView: View {
    @ObservedObject var vm: CullViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("IMPORT").font(.caption).bold().foregroundColor(.secondary)
                Spacer()
                Text("\(vm.photos.count)").font(.caption).foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(vm.photos.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            if let thumb = item.thumbnail {
                                Image(nsImage: thumb)
                                    .resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 42).cornerRadius(4)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(item.status.color, lineWidth: item.status == .none ? 0 : 3))
                            } else {
                                Rectangle().fill(Color.gray.opacity(0.2)).frame(width: 56, height: 42)
                            }
                            VStack(alignment: .leading) {
                                Text(item.filename).font(.system(size: 13, weight: .medium))
                                    .foregroundColor(index == vm.selectionIndex ? .white : .primary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .background(index == vm.selectionIndex ? Color.blue : Color.clear).cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.selectionIndex = index
                            vm.loadMainPreview()
                        }
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .onChange(of: vm.selectionIndex) { newIndex in
                    withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
                }
            }
        }
    }
}

struct StageView: View {
    @ObservedObject var vm: CullViewModel
    var body: some View {
        ZStack {
            Color(red: 0.1, green: 0.1, blue: 0.1) // Deep Dark
            if vm.photos.isEmpty {
                Button("打开文件夹 / Open Folder") { vm.loadFolder() }.controlSize(.large)
            } else {
                if vm.isComparing, let compareImg = vm.compareImage {
                    VStack {
                        Image(nsImage: compareImg).resizable().aspectRatio(contentMode: .fit)
                            .overlay(Text("👑 CURRENT KING").font(.headline).bold().padding(8).background(Color.green).foregroundColor(.white).cornerRadius(4).padding(), alignment: .topLeading)
                    }
                } else if let img = vm.currentImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                }
            }
        }
    }
}

struct ArenaView: View {
    @ObservedObject var vm: CullViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ARENA").font(.caption).bold().foregroundColor(.secondary)
                Spacer()
            }
            .padding().background(Color(NSColor.controlBackgroundColor))
            
            ScrollView {
                VStack(spacing: 20) {
                    if let king = vm.activeArena.king {
                        VStack(spacing: 5) {
                            Text("👑 KING").font(.caption).bold().foregroundColor(.green)
                            if let thumb = king.thumbnail {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                                    .cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green, lineWidth: 4))
                            }
                            Text(king.filename).font(.caption).foregroundColor(.secondary)
                        }
                        .padding().background(Color.white.opacity(0.05)).cornerRadius(12)
                    } else {
                        Text("Waiting for Challenger...").font(.caption).foregroundColor(.gray).frame(height: 100)
                    }
                    Divider().background(Color.gray.opacity(0.3))
                    if !vm.activeArena.princes.isEmpty {
                        ForEach(vm.activeArena.princes, id: \.id) { prince in
                            HStack {
                                if let thumb = prince.thumbnail {
                                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 40, height: 40).cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.yellow, lineWidth: 2))
                                }
                                VStack(alignment: .leading) {
                                    Text(prince.filename).font(.caption)
                                    Text("Loser").font(.caption2).foregroundColor(.yellow)
                                }
                                Spacer()
                            }
                            .padding(8).background(Color.white.opacity(0.03)).cornerRadius(8)
                        }
                    }
                    Spacer()
                }
                .padding()
            }
        }
        .background(Color(red: 0.13, green: 0.13, blue: 0.13))
    }
}

struct KeyMonitor: NSViewRepresentable {
    var vm: CullViewModel
    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.vm = vm
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    class KeyView: NSView {
        var vm: CullViewModel?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKey(event, isDown: true)
                return event
            }
            NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                self?.handleKey(event, isDown: false)
                return event
            }
        }
        func handleKey(_ event: NSEvent, isDown: Bool) {
            guard let vm = vm else { return }
            if event.charactersIgnoringModifiers == "c" {
                vm.setComparing(isDown)
                return
            }
            if isDown {
                switch event.charactersIgnoringModifiers {
                case "r": vm.triggerChallenge()
                case "f": vm.triggerFinalize()
                case "x", "2": vm.triggerReject()
                case "1": vm.triggerChallenge()
                case String(UnicodeScalar(NSUpArrowFunctionKey)!): vm.prevPhoto()
                case String(UnicodeScalar(NSDownArrowFunctionKey)!): vm.nextPhoto()
                default: break
                }
            }
        }
    }
}

@main
struct ArenaCullApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}
