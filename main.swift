import SwiftUI
import ImageIO

// MARK: - 1. 数据模型
struct PhotoItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let filename: String
    var isProcessed: Bool = false // 是否被处理过（进过擂台）
}

class Arena: Identifiable, ObservableObject {
    let id = UUID()
    @Published var king: PhotoItem?       // 绿标：当前的王
    @Published var princes: [PhotoItem] = [] // 黄标：被降级的图
    var isArchived: Bool = false
}

// MARK: - 2. 核心逻辑 (ViewModel)
class CullViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var selectionIndex: Int = 0
    @Published var currentImage: NSImage?
    
    // 所有的擂台，最后一个是活跃的
    @Published var arenas: [Arena] = [Arena()]
    
    var activeArena: Arena {
        return arenas.last ?? Arena()
    }
    
    // 支持的 RAW 格式
    let allowedExtensions = ["ARW", "CR2", "CR3", "NEF", "DNG", "RAF", "JPG", "JPEG"]
    
    // 加载文件夹
    func loadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                scanPhotos(at: url)
            }
        }
    }
    
    private func scanPhotos(at url: URL) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let rawFiles = files.filter { allowedExtensions.contains($0.pathExtension.uppercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            DispatchQueue.main.async {
                self.photos = rawFiles.map { PhotoItem(url: $0, filename: $0.lastPathComponent) }
                self.selectionIndex = 0
                self.arenas = [Arena()] // 重置擂台
                if !self.photos.isEmpty {
                    self.loadPreview()
                }
            }
        } catch {
            print("Error: \(error)")
        }
    }
    
    // 极速读取 RAW 预览图
    func loadPreview() {
        guard !photos.isEmpty, selectionIndex < photos.count else { return }
        let url = photos[selectionIndex].url
        
        DispatchQueue.global(qos: .userInteractive).async {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1500, // 足够清晰的预览
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                DispatchQueue.main.async {
                    self.currentImage = nsImage
                }
            }
        }
    }
    
    // --- 核心业务逻辑 ---
    
    // R键：挑战擂台
    func triggerChallenge() {
        guard !photos.isEmpty else { return }
        var challenger = photos[selectionIndex]
        
        // 标记为已处理（左侧列表变暗）
        photos[selectionIndex].isProcessed = true
        
        let arena = activeArena
        
        if let oldKing = arena.king {
            // 如果已有王，旧王退位，进入替补席（顶部插入）
            if oldKing.id != challenger.id { // 防止重复添加同一张
                arena.princes.insert(oldKing, at: 0)
            }
        }
        
        // 新王登基
        arena.king = challenger
        // 强制刷新UI
        objectWillChange.send()
    }
    
    // F键：存档并开启新擂台
    func triggerFinalize() {
        activeArena.isArchived = true
        arenas.append(Arena()) // 创建新擂台，UI会自动清空右侧
        objectWillChange.send()
    }
    
    // 导航
    func nextPhoto() {
        if selectionIndex < photos.count - 1 {
            selectionIndex += 1
            loadPreview()
        }
    }
    
    func prevPhoto() {
        if selectionIndex > 0 {
            selectionIndex -= 1
            loadPreview()
        }
    }
}

// MARK: - 3. 界面布局 (View)
struct ContentView: View {
    @StateObject var vm = CullViewModel()
    
    var body: some View {
        HSplitView {
            // Zone 1: 待选池 (左侧窄栏)
            VStack(alignment: .leading) {
                Text("待选池 \(vm.selectionIndex + 1)/\(vm.photos.count)")
                    .font(.caption)
                    .padding(5)
                
                List(0..<vm.photos.count, id: \.self) { index in
                    let item = vm.photos[index]
                    HStack {
                        // 简单的状态点
                        Circle()
                            .fill(index == vm.selectionIndex ? Color.blue : (item.isProcessed ? Color.gray : Color.white))
                            .frame(width: 8, height: 8)
                        Text(item.filename)
                            .font(.system(size: 12))
                            .foregroundColor(item.isProcessed ? .gray : .primary)
                    }
                    .listRowBackground(index == vm.selectionIndex ? Color.blue.opacity(0.2) : Color.clear)
                    .onTapGesture {
                        vm.selectionIndex = index
                        vm.loadPreview()
                    }
                }
            }
            .frame(minWidth: 150, maxWidth: 200)
            
            // Zone 2: 聚光灯 (中间大图)
            ZStack {
                Color.black
                if let img = vm.currentImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack {
                        Text("ArenaCull").font(.largeTitle).foregroundColor(.gray)
                        Button("打开文件夹") { vm.loadFolder() }
                            .padding()
                    }
                }
            }
            .frame(minWidth: 400)
            
            // Zone 3: 擂台榜 (右侧)
            VStack(spacing: 0) {
                Text("当前擂台").font(.headline).padding()
                
                // 👑 现任王座 (绿)
                ZStack {
                    Rectangle().fill(Color.black)
                    if let king = vm.activeArena.king {
                        VStack {
                            Text("👑 WINNER").font(.caption).foregroundColor(.green).bold()
                            Text(king.filename).foregroundColor(.white)
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.green, lineWidth: 4))
                    } else {
                        Text("空缺").foregroundColor(.gray)
                    }
                }
                .frame(height: 150)
                .padding()
                
                Divider()
                
                // ⚠️ 替补席 (黄)
                List(vm.activeArena.princes, id: \.id) { prince in
                    HStack {
                        Text("⚠️")
                        Text(prince.filename)
                        Spacer()
                    }
                    .padding(5)
                    .background(Color.yellow.opacity(0.2))
                    .cornerRadius(5)
                }
            }
            .frame(minWidth: 200, maxWidth: 250)
        }
        // 绑定键盘快捷键
        .background(Button(action: { vm.prevPhoto() }) { EmptyView() }.keyboardShortcut(.upArrow, modifiers: []))
        .background(Button(action: { vm.nextPhoto() }) { EmptyView() }.keyboardShortcut(.downArrow, modifiers: []))
        .background(Button(action: { vm.triggerChallenge() }) { EmptyView() }.keyboardShortcut("r", modifiers: [])) // R键
        .background(Button(action: { vm.triggerFinalize() }) { EmptyView() }.keyboardShortcut("f", modifiers: []))  // F键
        .frame(minWidth: 800, minHeight: 600)
    }
}

@main
struct ArenaCullApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
