import SwiftUI
import ImageIO
import AppKit

// MARK: - 1. 数据模型
struct PhotoItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let filename: String
    var isProcessed: Bool = false
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
    
    var activeArena: Arena {
        return arenas.last ?? Arena()
    }
    
    let allowedExtensions = ["ARW", "CR2", "CR3", "NEF", "DNG", "RAF", "JPG", "JPEG"]
    
    func loadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择包含 RAW 照片的文件夹"
        
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
                self.arenas = [Arena()]
                if !self.photos.isEmpty {
                    self.loadPreview()
                }
            }
        } catch {
            print("Error: \(error)")
        }
    }
    
    func loadPreview() {
        guard !photos.isEmpty, selectionIndex < photos.count else { return }
        let url = photos[selectionIndex].url
        
        DispatchQueue.global(qos: .userInteractive).async {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1500,
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
    
    func triggerChallenge() {
        guard !photos.isEmpty else { return }
        let challenger = photos[selectionIndex]
        
        photos[selectionIndex].isProcessed = true
        
        let arena = activeArena
        
        if let oldKing = arena.king {
            if oldKing.id != challenger.id {
                arena.princes.insert(oldKing, at: 0)
            }
        }
        arena.king = challenger
        objectWillChange.send()
    }
    
    func triggerFinalize() {
        activeArena.isArchived = true
        arenas.append(Arena())
        objectWillChange.send()
    }
    
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
            // Zone 1: 待选池
            VStack(alignment: .leading) {
                Text("待选池 \(vm.selectionIndex + 1)/\(vm.photos.count)")
                    .font(.caption)
                    .padding(5)
                
                List(0..<vm.photos.count, id: \.self) { index in
                    let item = vm.photos[index]
                    HStack {
                        Circle()
                            .fill(index == vm.selectionIndex ? Color.blue : (item.isProcessed ? Color.gray : Color.white))
                            .frame(width: 8, height: 8)
                        Text(item.filename)
                            .font(.system(size: 12))
                            .foregroundColor(item.isProcessed ? .gray : .primary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        vm.selectionIndex = index
                        vm.loadPreview()
                    }
                    .listRowBackground(index == vm.selectionIndex ? Color.blue.opacity(0.2) : Color.clear)
                }
            }
            .frame(minWidth: 150, maxWidth: 200)
            
            // Zone 2: 聚光灯
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
            
            // Zone 3: 擂台榜
            VStack(spacing: 0) {
                Text("当前擂台").font(.headline).padding()
                
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
        .background(Button(action: { vm.prevPhoto() }) { EmptyView() }.keyboardShortcut(.upArrow, modifiers: []))
        .background(Button(action: { vm.nextPhoto() }) { EmptyView() }.keyboardShortcut(.downArrow, modifiers: []))
        .background(Button(action: { vm.triggerChallenge() }) { EmptyView() }.keyboardShortcut("r", modifiers: []))
        .background(Button(action: { vm.triggerFinalize() }) { EmptyView() }.keyboardShortcut("f", modifiers: []))
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
