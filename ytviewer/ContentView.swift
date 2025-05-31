import SwiftUI
import AVFoundation
import Photos
import UniformTypeIdentifiers

// MARK: - Models
enum DownloadFormat: String, CaseIterable, Identifiable {
    case mp4_1080p = "MP4 1080p (видео)"
    case mp4_720p = "MP4 720p (видео)"
    case mp4_480p = "MP4 480p (видео)"
    case mp3_320 = "MP3 320kbps (аудио)"
    case mp3_256 = "MP3 256kbps (аудио)"
    case mp3_128 = "MP3 128kbps (аудио)"
    
    var id: String { rawValue }
    var isVideo: Bool { rawValue.contains("MP4") }
    var fileExtension: String { isVideo ? "mp4" : "mp3" }
}

enum SaveLocation: String, CaseIterable, Identifiable {
    case gallery = "Галерея"
    case files = "Файлы"
    var id: String { rawValue }
}

enum DownloadState {
    case idle
    case preparing
    case downloading(progress: Double)
    case completed
    case failed(error: String)
}

// MARK: - Download Manager
class DownloadManager: ObservableObject {
    @Published var downloadState: DownloadState = .idle
    @Published var downloadedFileURL: URL?
    
    // Адрес сервера для скачивания
    private let serverURL = "http://192.168.1.100:5000/download" // <-- Укажи свой IP и порт
    
    func downloadVideo(url: String, format: DownloadFormat, saveLocation: SaveLocation, completion: @escaping (Bool, String?) -> Void) {
        guard isValidYouTubeURL(url) else {
            downloadState = .failed(error: "Неверная ссылка на YouTube")
            completion(false, "Неверная ссылка на YouTube")
            return
        }
        downloadState = .preparing
        // Формируем запрос к серверу
        let normalizedURL = normalizeYouTubeURL(url)
        guard var components = URLComponents(string: serverURL) else {
            downloadState = .failed(error: "Ошибка адреса сервера")
            completion(false, "Ошибка адреса сервера")
            return
        }
        components.queryItems = [URLQueryItem(name: "url", value: normalizedURL)]
        guard let requestURL = components.url else {
            downloadState = .failed(error: "Ошибка формирования запроса")
            completion(false, "Ошибка формирования запроса")
            return
        }
        downloadState = .downloading(progress: 0.0)
        let task = URLSession.shared.downloadTask(with: requestURL) { tempURL, response, error in
            if let tempURL, error == nil {
                let fileName = UUID().uuidString + "." + format.fileExtension
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destinationURL = documentsPath.appendingPathComponent(fileName)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    DispatchQueue.main.async {
                        self.downloadedFileURL = destinationURL
                        self.downloadState = .completed
                        if format.isVideo && saveLocation == .gallery {
                            self.saveVideoToGallery(url: destinationURL) { success, error in
                                completion(success, error)
                            }
                        } else {
                            completion(true, nil)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.downloadState = .failed(error: "Ошибка сохранения файла")
                        completion(false, "Ошибка сохранения файла")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.downloadState = .failed(error: "Ошибка скачивания файла")
                    completion(false, "Ошибка скачивания файла")
                }
            }
        }
        task.resume()
    }
    
    private func normalizeYouTubeURL(_ url: String) -> String {
        // Удаляем параметры
        let cleanURL = url.components(separatedBy: "?").first ?? url
        // Если короткая ссылка, преобразуем в полную
        if let match = cleanURL.range(of: "youtu.be/([a-zA-Z0-9_-]{11})", options: .regularExpression) {
            let videoId = String(cleanURL[match]).replacingOccurrences(of: "youtu.be/", with: "")
            return "https://www.youtube.com/watch?v=\(videoId)"
        }
        return cleanURL
    }
    
    private func saveVideoToGallery(url: URL, completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            completion(true, nil)
                        } else {
                            completion(false, error?.localizedDescription ?? "Ошибка сохранения в галерею")
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(false, "Нет доступа к галерее")
                }
            }
        }
    }
    
    private func isValidYouTubeURL(_ url: String) -> Bool {
        let youtubePatterns = [
            "^https?://(?:www\\.)?youtube\\.com/watch\\?v=([a-zA-Z0-9_-]{11})",
            "^https?://(?:www\\.)?youtu\\.be/([a-zA-Z0-9_-]{11})",
            "^https?://(?:www\\.)?youtube\\.com/embed/([a-zA-Z0-9_-]{11})"
        ]
        for pattern in youtubePatterns {
            if url.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
    
    private func extractVideoId(from url: String) -> String {
        let patterns = [
            "(?:youtube\\.com/watch\\?v=|youtu\\.be/|youtube\\.com/embed/)([a-zA-Z0-9_-]{11})"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) {
                if let range = Range(match.range(at: 1), in: url) {
                    return String(url[range])
                }
            }
        }
        return "unknown"
    }
    
    func resetDownload() {
        downloadState = .idle
        downloadedFileURL = nil
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var downloadManager = DownloadManager()
    @State private var youtubeURL: String = ""
    @State private var showFormatSheet = false
    @State private var selectedFormat: DownloadFormat = .mp4_720p
    @State private var showSaveLocationSheet = false
    @State private var selectedSaveLocation: SaveLocation = .gallery
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showSuccess = false
    @State private var showDocumentPicker = false
    @State private var fileToShare: URL?
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(.systemGray6), Color(.systemGray4)]), startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 32) {
                headerView
                urlInputSection
                downloadButton
                downloadSection
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .sheet(isPresented: $showFormatSheet) {
                FormatPickerView(selectedFormat: $selectedFormat, onDone: {
                    showFormatSheet = false
                    showSaveLocationSheet = true
                })
            }
            .sheet(isPresented: $showSaveLocationSheet) {
                SaveLocationPickerView(selectedSaveLocation: $selectedSaveLocation, onDone: {
                    showSaveLocationSheet = false
                    startDownload()
                })
            }
            .sheet(isPresented: $showDocumentPicker) {
                if let fileToShare {
                    DocumentPicker(fileURL: fileToShare)
                }
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Внимание"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
            if showSuccess {
                SuccessToastView(message: "Скачивание завершено!", onDismiss: { showSuccess = false })
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .resizable()
                .frame(width: 70, height: 70)
                .foregroundStyle(LinearGradient(colors: [.red, .orange], startPoint: .top, endPoint: .bottom))
                .shadow(radius: 8)
            Text("YouTube Загрузчик")
                .font(.largeTitle).fontWeight(.bold)
                .foregroundColor(.primary)
            Text("Скачайте видео или аудио с YouTube в нужном качестве и выберите место сохранения.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var urlInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ссылка на YouTube видео")
                .font(.headline)
            HStack {
                TextField("https://youtube.com/watch?v=...", text: $youtubeURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if !youtubeURL.isEmpty {
                    Button(action: { youtubeURL = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            if !youtubeURL.isEmpty && !isValidYouTubeURL(youtubeURL) {
                Text("Пожалуйста, введите корректную ссылку на YouTube")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
    
    private var downloadButton: some View {
        Button(action: {
            if canDownload {
                showFormatSheet = true
            } else {
                alertMessage = "Введите корректную ссылку на YouTube"
                showAlert = true
            }
        }) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                Text("Скачать")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                Group {
                    if canDownload {
                        LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                    } else {
                        Color.gray
                    }
                }
            )
            .cornerRadius(16)
            .shadow(color: .gray.opacity(0.3), radius: 8, x: 0, y: 4)
            .scaleEffect(canDownload ? 1.0 : 0.98)
            .animation(.spring(), value: canDownload)
        }
        .disabled(!canDownload)
    }
    
    private var downloadSection: some View {
        VStack(spacing: 20) {
            switch downloadManager.downloadState {
            case .idle:
                EmptyView()
            case .preparing:
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Подготовка к скачиванию...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            case .downloading(let progress):
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .scaleEffect(1.1)
                    Text("Скачивание: \(Int(progress * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            case .completed:
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.green)
                        .shadow(radius: 6)
                    Text("Скачивание завершено!")
                        .font(.headline)
                        .foregroundColor(.green)
                    if selectedFormat.isVideo && selectedSaveLocation == .gallery {
                        Text("Видео сохранено в галерею")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Файл сохранён в файлы")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 16) {
                        Button(action: {
                            if let url = downloadManager.downloadedFileURL {
                                fileToShare = url
                                showDocumentPicker = true
                            }
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Открыть в файлах")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("Скачать ещё") {
                            downloadManager.resetDownload()
                            youtubeURL = ""
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            case .failed(let error):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.red)
                        .shadow(radius: 6)
                    Text("Ошибка")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Попробовать снова") {
                        downloadManager.resetDownload()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(.top, 8)
    }
    
    private var canDownload: Bool {
        !youtubeURL.isEmpty && isValidYouTubeURL(youtubeURL)
    }
    
    private func startDownload() {
        if selectedFormat.isVideo && selectedSaveLocation == .gallery {
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        downloadManager.downloadVideo(url: youtubeURL, format: selectedFormat, saveLocation: selectedSaveLocation) { success, error in
                            if success {
                                showSuccess = true
                            } else {
                                alertMessage = error ?? "Ошибка сохранения"
                                showAlert = true
                            }
                        }
                    } else {
                        alertMessage = "Для сохранения видео в галерею необходимо разрешение на доступ к фото"
                        showAlert = true
                    }
                }
            }
        } else {
            downloadManager.downloadVideo(url: youtubeURL, format: selectedFormat, saveLocation: selectedSaveLocation) { success, error in
                if success {
                    showSuccess = true
                } else {
                    alertMessage = error ?? "Ошибка сохранения"
                    showAlert = true
                }
            }
        }
    }
    
    private func isValidYouTubeURL(_ url: String) -> Bool {
        let youtubePatterns = [
            "^https?://(?:www\\.)?youtube\\.com/watch\\?v=([a-zA-Z0-9_-]{11})",
            "^https?://(?:www\\.)?youtu\\.be/([a-zA-Z0-9_-]{11})",
            "^https?://(?:www\\.)?youtube\\.com/embed/([a-zA-Z0-9_-]{11})"
        ]
        for pattern in youtubePatterns {
            if url.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}

// MARK: - Format Picker Modal
struct FormatPickerView: View {
    @Binding var selectedFormat: DownloadFormat
    var onDone: () -> Void
    @Environment(\.presentationMode) var presentationMode
    var body: some View {
        NavigationView {
            List {
                ForEach(DownloadFormat.allCases) { format in
                    HStack {
                        Text(format.rawValue)
                        Spacer()
                        if format == selectedFormat {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedFormat = format
                    }
                }
            }
            .navigationTitle("Выберите формат")
            .navigationBarItems(trailing: Button("Далее") {
                onDone()
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// MARK: - Save Location Picker Modal
struct SaveLocationPickerView: View {
    @Binding var selectedSaveLocation: SaveLocation
    var onDone: () -> Void
    @Environment(\.presentationMode) var presentationMode
    var body: some View {
        NavigationView {
            List {
                ForEach(SaveLocation.allCases) { location in
                    HStack {
                        Text(location.rawValue)
                        Spacer()
                        if location == selectedSaveLocation {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedSaveLocation = location
                    }
                }
            }
            .navigationTitle("Куда сохранить?")
            .navigationBarItems(trailing: Button("Скачать") {
                onDone()
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// MARK: - Document Picker
struct DocumentPicker: UIViewControllerRepresentable {
    let fileURL: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

// MARK: - Success Toast
struct SuccessToastView: View {
    let message: String
    var onDismiss: () -> Void
    @State private var opacity: Double = 1.0
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.white)
                Text(message)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
            }
            .padding()
            .background(LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing))
            .cornerRadius(16)
            .shadow(radius: 8)
            .padding(.bottom, 40)
            .opacity(opacity)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        opacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        onDismiss()
                    }
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut, value: opacity)
    }
}

// MARK: - Custom Button Styles
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}
