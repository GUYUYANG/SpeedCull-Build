import SwiftUI
import ImageIO
import AppKit

// MARK: - 1. 数据模型与枚举
enum CullStatus: String {
    case none
    case winner // 绿 (King)
    case loser  // 黄 (Prince)
    case reject // 红 (Trash)
    
    var color: Color {
        switch self {
        case .none: return .gray.opacity(0.3)
        case .winner: return .green
        case .loser: return .yellow
        case .reject: return .red
        }
    }
}

struct PhotoItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let filename: String
    var status: CullStatus = .none
}

class Arena: Identifiable, ObservableObject {
    let id = UUID()
    @Published var king: PhotoItem?
    @Published var princes: [PhotoItem] = []
    var isArchived: Bool = false
}

// MARK: - 2. 核心逻辑 (ViewModel)
class CullViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var selectionIndex: Int = 0
    @Published var currentImage: NSImage?
    
    @Published var arenas: [Arena] = [Arena()]
    var activeArena: Arena { arenas.last ?? Arena() }
    
    let allowedExtensions = ["ARW", "CR2", "CR3", "NEF", "DNG", "RAF", "JPG", "JPEG"]
    
    // 打开文件夹
    func loadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择 RAW 文件夹"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                scanPhotos(at: url)
            }
        }
    }
    
    private func scanPhotos(at url: URL) {
        do {
            // 请求读取标签权限
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.tagNamesKey])
            
            let rawFiles = files.filter { allowedExtensions.contains($0.pathExtension.uppercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            DispatchQueue.main.async {
                self.photos = rawFiles.map { url in
                    // 读取现有的 Finder 标签
                    let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                    var status: CullStatus = .none
                    if tags.contains("Green") { status = .winner }
                    else if tags.contains("Yellow") { status = .loser }
                    else if tags.contains("Red") { status = .reject }
                    
                    return PhotoItem(url: url, filename: url.lastPathComponent, status: status)
                }
                self.selectionIndex = 0
                self.arenas = [Arena()]
                if !self.photos.isEmpty { self.loadMainPreview() }
            }
        } catch { print("Error: \(error)") }
    }
    
    // 加载中间大图
    func loadMainPreview() {
        guard !photos.isEmpty, selectionIndex < photos.count else { return }
        let url = photos[selectionIndex].url
        DispatchQueue.global(qos: .userInteractive).async {
            if let nsImage = self.extractThumbnail(from: url, maxPixelSize: 1800) {
                DispatchQueue.main.async { self.currentImage = nsImage }
            }
        }
    }
    
    func extractThumbnail(from url: URL, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    // --- 核心操作 ---
    
    // 写入 Finder 标签 (已彻底修复)
    func setFinderTag(for item: PhotoItem, tag: String?) {
        var fileUrl = item.url
        do {
            let tags: [String] = tag != nil ? [tag!] : []
            
            // 修复点：使用最标准的 URLResourceValues 写法
            var resourceValues = URLResourceValues()
            resourceValues.tagNames = tags
            try fileUrl.setResourceValues(resourceValues)
            
        } catch {
            print("无法写入标签: \(error)")
        }
    }
    
    // R键：挑战擂台
    func triggerChallenge() {
        guard !photos.isEmpty else { return }
        var challenger = photos[selectionIndex]
        
        challenger.status = .winner
        photos[selectionIndex] = challenger
        setFinderTag(for: challenger, tag: "Green")
        
        let arena = activeArena
        
        if var oldKing = arena.king {
            if oldKing.id != challenger.id {
                oldKing.status = .loser
                setFinderTag(for: oldKing, tag: "Yellow")
                
                if let idx = photos.firstIndex(where: { $0.id == oldKing.id }) {
                    photos[idx] = oldKing
                }
                arena.princes.insert(oldKing, at: 0)
            }
        }
        
        arena.king = challenger
        objectWillChange.send()
    }
    
    // X键 (或2): 标记废片
    func triggerReject() {
        guard !photos.isEmpty else { return }
        var item = photos[selectionIndex]
        item.status = .reject
        photos[selectionIndex] = item
        setFinderTag(for: item, tag: "Red")
        nextPhoto()
    }
    
    // F键：存档
    func triggerFinalize() {
        activeArena.isArchived = true
        arenas.append(Arena())
        objectWillChange.send()
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
}

// MARK: - 3. UI 组件

struct AsyncThumbnailView: View {
    let url: URL
    @State private var image: NSImage?
    
    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: 50, height: 50)
        .clipped()
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 150,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    let nsImg = NSImage(cgImage: cgImage, size: NSSize(width: 50, height: 50))
                    DispatchQueue.main.async { self.image = nsImg }
                }
            }
        }
    }
}

// MARK: - 4. 主视图
struct ContentView: View {
    @StateObject var vm = CullViewModel()
    
    var body: some View {
        HSplitView {
            // Zone 1: 侧边栏
            VStack(spacing: 0) {
                HStack {
                    Text("图库")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(vm.photos.count) 张")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
                
                List {
                    ForEach(Array(vm.photos.enumerated()), id: \.element) { index, item in
                        HStack {
                            AsyncThumbnailView(url: item.url)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(item.status.color, lineWidth: item.status == .none ? 0 : 3)
                                )
                            
                            VStack(alignment: .leading) {
                                Text(item.filename)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                if item.status != .none {
                                    Text(item.status == .winner ? "WIN" : (item.status == .reject ? "REJECT" : "OUT"))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(item.status.color)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .listRowBackground(vm.selectionIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                        .onTapGesture {
                            vm.selectionIndex = index
                            vm.loadMainPreview()
                        }
                        .id(index)
                    }
                }
                .listStyle(SidebarListStyle())
            }
            .frame(minWidth: 220, maxWidth: 300)
            
            // Zone 2: 舞台
            ZStack {
                Color(NSColor.windowBackgroundColor)
                
                if let img = vm.currentImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Button("打开文件夹 (Open Folder)") {
                            vm.loadFolder()
                        }
                        .controlSize(.large)
                    }
                }
            }
            .frame(minWidth: 500)
            
            // Zone 3: 竞技场
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "trophy.fill").foregroundColor(.yellow)
                    Text("ARENA").font(.headline).bold()
                    Spacer()
                }
                .padding()
                .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
                
                ScrollView {
                    VStack(spacing: 15) {
                        if let king = vm.activeArena.king {
                            VStack {
                                Text("👑 WINNER").font(.caption).bold().foregroundColor(.green)
                                AsyncThumbnailView(url: king.url)
                                    .frame(width: 120, height: 120)
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green, lineWidth: 4))
                                    .shadow(color: .green.opacity(0.5), radius: 10, x: 0, y: 0)
                                Text(king.filename).font(.caption).bold()
                            }
                            .padding()
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(12)
                        } else {
                            VStack {
                                Image(systemName: "crown").font(.largeTitle).foregroundColor(.gray)
                                Text("等待挑战者...").font(.caption).foregroundColor(.gray)
                            }
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.3), lineWidth: 2))
                        }
                        
                        Divider().padding(.vertical)
                        
                        if !vm.activeArena.princes.isEmpty {
                            Text("HISTORY").font(.caption).foregroundColor(.secondary)
                            ForEach(vm.activeArena.princes, id: \.id) { prince in
                                HStack {
                                    AsyncThumbnailView(url: prince.url)
                                        .frame(width: 40, height: 40)
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.yellow, lineWidth: 2))
                                    
                                    VStack(alignment: .leading) {
                                        Text(prince.filename).font(.caption)
                                        Text("Out").font(.caption2).foregroundColor(.yellow)
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .background(Color.yellow.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                }
            }
            .frame(minWidth: 200, maxWidth: 260)
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        }
        .background(Button(action: { vm.prevPhoto() }) { EmptyView() }.keyboardShortcut(.upArrow, modifiers: []))
        .background(Button(action: { vm.nextPhoto() }) { EmptyView() }.keyboardShortcut(.downArrow, modifiers: []))
        .background(Button(action: { vm.triggerChallenge() }) { EmptyView() }.keyboardShortcut("r", modifiers: []))
        .background(Button(action: { vm.triggerReject() }) { EmptyView() }.keyboardShortcut("2", modifiers: []))
        .background(Button(action: { vm.triggerReject() }) { EmptyView() }.keyboardShortcut("x", modifiers: []))
        .background(Button(action: { vm.triggerFinalize() }) { EmptyView() }.keyboardShortcut("f", modifiers: []))
        .frame(minWidth: 1000, minHeight: 700)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
