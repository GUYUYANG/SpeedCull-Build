import SwiftUI
import ImageIO
import AppKit

// MARK: - 1. 数据模型
enum CullStatus: String {
    case none
    case winner // 绿 (King)
    case loser  // 黄 (Prince)
    case reject // 红 (Trash)
    
    var color: Color {
        switch self {
        case .none: return Color.gray.opacity(0.3)
        case .winner: return Color(hex: 0x4CD964) // iOS Green
        case .loser: return Color(hex: 0xFFCC00)  // iOS Yellow
        case .reject: return Color(hex: 0xFF3B30) // iOS Red
        }
    }
    
    var tagName: String? {
        switch self {
        case .winner: return "Green"
        case .loser: return "Yellow"
        case .reject: return "Red"
        case .none: return nil
        }
    }
}

// 扩展颜色支持
extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 08) & 0xff) / 255,
            blue: Double((hex >> 00) & 0xff) / 255,
            opacity: alpha
        )
    }
}

class PhotoItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let filename: String
    @Published var status: CullStatus = .none
    @Published var thumbnail: NSImage? // 预加载的小图
    
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
    @Published var compareImage: NSImage? // 用于 C 键对比的图
    
    @Published var arenas: [Arena] = [Arena()]
    var activeArena: Arena { arenas.last ?? Arena() }
    
    // 加载状态
    @Published var isLoading: Bool = false
    @Published var loadProgress: Double = 0.0
    @Published var loadingMessage: String = ""
    
    // 对比状态
    @Published var isComparing: Bool = false
    
    let allowedExtensions = ["ARW", "CR2", "CR3", "NEF", "DNG", "RAF", "JPG", "JPEG", "PNG"]
    
    // MARK: - 文件加载与预处理
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
                
                // 批量预加载缩略图
                for (index, fileUrl) in rawFiles.enumerated() {
                    // 读取 Finder 标签
                    let tags = (try? fileUrl.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                    var status: CullStatus = .none
                    if tags.contains("Green") { status = .winner }
                    else if tags.contains("Yellow") { status = .loser }
                    else if tags.contains("Red") { status = .reject }
                    
                    let item = PhotoItem(url: fileUrl, filename: fileUrl.lastPathComponent, status: status)
                    
                    // 同步生成小缩略图 (速度很快，存入内存)
                    item.thumbnail = self.generateThumbnail(from: fileUrl, size: 150)
                    loadedItems.append(item)
                    
                    // 更新进度
                    DispatchQueue.main.async {
                        self.loadProgress = Double(index + 1) / total
                        self.loadingMessage = "正在预加载缩略图 \(index + 1)/\(Int(total))"
                    }
                }
                
                // 完成
                DispatchQueue.main.async {
                    self.photos = loadedItems
                    self.selectionIndex = 0
                    self.arenas = [Arena()]
                    self.isLoading = false
                    if !self.photos.isEmpty {
                        self.loadMainPreview()
                    }
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    print("Error: \(error)")
                }
            }
        }
    }
    
    // MARK: - 图像处理
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
        
        // 加载当前大图
        DispatchQueue.global(qos: .userInteractive).async {
            if let nsImage = self.generateThumbnail(from: url, size: 1800) {
                DispatchQueue.main.async { self.currentImage = nsImage }
            }
        }
        
        // 预加载对比图（当前擂台的王）
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
    
    // MARK: - 核心业务逻辑
    
    // 写入 Finder 标签 (最标准写法)
    func setFinderTag(for item: PhotoItem, tag: String?) {
        var fileUrl = item.url
        var newValues = URLResourceValues()
        // 注意：这里是覆盖写入。如果你想保留其他标签，需要先读取再 append。
        // 为了选片效率，这里逻辑是：状态即标签。
        newValues.tagNames = tag != nil ? [tag!] : []
        
        do {
            try fileUrl.setResourceValues(newValues)
        } catch {
            print("Tag Error: \(error)")
        }
    }
    
    // R键：挑战擂台
    func triggerChallenge() {
        guard !photos.isEmpty else { return }
        let challenger = photos[selectionIndex]
        
        // 1. 设置当前图为王 (绿)
        challenger.status = .winner
        setFinderTag(for: challenger, tag: "Green")
        
        let arena = activeArena
        
        // 2. 如果有旧王，旧王退位 (黄)
        if let oldKing = arena.king {
            if oldKing.id != challenger.id {
                oldKing.status = .loser
                setFinderTag(for: oldKing, tag: "Yellow")
                
                // 更新UI显示（因为 PhotoItem 是 Class，引用类型，这里自动更新）
                arena.princes.insert(oldKing, at: 0)
            }
        }
        
        // 3. 上位
        arena.king = challenger
        objectWillChange.send()
        
        // 重新加载对比图，因为王变了
        loadMainPreview()
    }
    
    // F键：新擂台 (结算旧的，当前图开启新的)
    func triggerFinalize() {
        guard !photos.isEmpty else { return }
        let currentPhoto = photos[selectionIndex]
        
        // 1. 存档旧擂台
        activeArena.isArchived = true
        
        // 2. 创建新擂台
        let newArena = Arena()
        arenas.append(newArena)
        
        // 3. 当前图直接称王
        currentPhoto.status = .winner
        setFinderTag(for: currentPhoto, tag: "Green")
        newArena.king = currentPhoto
        
        objectWillChange.send()
        loadMainPreview()
    }
    
    // X键：废片
    func triggerReject() {
        guard !photos.isEmpty else { return }
        let item = photos[selectionIndex]
        
        item.status = .reject
        setFinderTag(for: item, tag: "Red")
        
        nextPhoto()
    }
    
    // 导航
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
    
    // C键逻辑
    func setComparing(_ comparing: Bool) {
        if isComparing != comparing {
            isComparing = comparing
        }
    }
}

// MARK: - 3. UI 界面
struct ContentView: View {
    @StateObject var vm = CullViewModel()
    
    var body: some View {
        ZStack {
            HSplitView {
                // Zone 1: 侧边栏
                SidebarView(vm: vm)
                    .frame(minWidth: 250, maxWidth: 300)
                
                // Zone 2: 舞台
                StageView(vm: vm)
                    .frame(minWidth: 500)
                
                // Zone 3: 竞技场
                ArenaView(vm: vm)
                    .frame(minWidth: 220, maxWidth: 280)
            }
            
            // Loading 遮罩
            if vm.isLoading {
                ZStack {
                    Color.black.opacity(0.8)
                    VStack(spacing: 20) {
                        ProgressView(value: vm.loadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                            .frame(width: 300)
                        Text(vm.loadingMessage)
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                }
                .edgesIgnoringSafeArea(.all)
            }
        }
        // 全局键盘监听 (包括按住 C)
        .background(KeyMonitor(vm: vm))
        .frame(minWidth: 1000, minHeight: 700)
    }
}

// 侧边栏组件
struct SidebarView: View {
    @ObservedObject var vm: CullViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("IMPORT").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                Spacer()
                Text("\(vm.photos.count)").font(.caption).foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(vm.photos.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            // 缩略图
                            if let thumb = item.thumbnail {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 42)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(item.status.color, lineWidth: item.status == .none ? 0 : 3)
                                    )
                            } else {
                                Rectangle().fill(Color.gray.opacity(0.2)).frame(width: 56, height: 42)
                            }
                            
                            // 文件名与状态
                            VStack(alignment: .leading) {
                                Text(item.filename)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(index == vm.selectionIndex ? .white : .primary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(index == vm.selectionIndex ? Color.blue : Color.clear)
                        .cornerRadius(6)
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

// 舞台组件 (大图)
struct StageView: View {
    @ObservedObject var vm: CullViewModel
    
    var body: some View {
        ZStack {
            Color(hex: 0x1A1A1A) // 深色背景
            
            if vm.photos.isEmpty {
                Button("打开文件夹 / Open Folder") { vm.loadFolder() }
                    .controlSize(.large)
            } else {
                // 显示逻辑：如果按住了 C 且有对比图，显示对比图；否则显示当前图
                if vm.isComparing, let compareImg = vm.compareImage {
                    VStack {
                        Image(nsImage: compareImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay(
                                Text("COMPARING: WINNER")
                                    .font(.headline)
                                    .padding(8)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                                    .padding(),
                                alignment: .topLeading
                            )
                    }
                } else if let img = vm.currentImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
        }
    }
}

// 竞技场组件 (右侧)
struct ArenaView: View {
    @ObservedObject var vm: CullViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ARENA").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            ScrollView {
                VStack(spacing: 20) {
                    // 👑 现任王座
                    if let king = vm.activeArena.king {
                        VStack(spacing: 5) {
                            Text("👑 KING").font(.caption).fontWeight(.black).foregroundColor(.green)
                            
                            if let thumb = king.thumbnail {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green, lineWidth: 4))
                            }
                            Text(king.filename).font(.caption).foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)
                    } else {
                        Text("Waiting for Challenger...")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .frame(height: 100)
                    }
                    
                    Divider().background(Color.gray.opacity(0.3))
                    
                    // ⚠️ 替补席
                    if !vm.activeArena.princes.isEmpty {
                        ForEach(vm.activeArena.princes, id: \.id) { prince in
                            HStack {
                                if let thumb = prince.thumbnail {
                                    Image(nsImage: thumb)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 40, height: 40)
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.yellow, lineWidth: 2))
                                }
                                VStack(alignment: .leading) {
                                    Text(prince.filename).font(.caption)
                                    Text("Loser").font(.caption2).foregroundColor(.yellow)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(8)
                        }
                    }
                    
                    Spacer()
                }
                .padding()
            }
        }
        .background(Color(hex: 0x222222))
    }
}

// MARK: - 键盘事件监听 (NSEvent)
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
            // 监听键盘事件
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
            
            // 按住 C 对比
            if event.charactersIgnoringModifiers == "c" {
                vm.setComparing(isDown)
                return
            }
            
            // 其他快捷键仅在按下时触发
            if isDown {
                switch event.charactersIgnoringModifiers {
                case "r": vm.triggerChallenge()
                case "f": vm.triggerFinalize()
                case "x", "2": vm.triggerReject()
                case "1": vm.triggerChallenge() // 兼容按键
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
