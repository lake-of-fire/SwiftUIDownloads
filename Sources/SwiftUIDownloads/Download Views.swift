import SwiftUI

public struct DownloadProgress: View {
    @ObservedObject var download: Downloadable
    let retryAction: (() -> Void)
    let redownloadAction: (() -> Void)
    
    private var statusText: String {
        if download.isFinishedProcessing {
            return "Finished"
        }
        switch download.downloadProgress {
        case .downloading(let progress):
            var str = "\(round((Double(progress.completedUnitCount) / 1_000_000) * 10) / 10)MB of \(round((Double(progress.totalUnitCount) / 1_000_000) * 10) / 10)MB"
//              TODO: print("File size = " + ByteCountFormatter().string(fromByteCount: Int64(fileSize)))
            if let throughput = progress.throughput {
                str += " at \(round((Double(throughput) / 1_000_000) * 10) / 10)MB/s"
            }
            return str
        case .waitingForResponse:
            return "Waiting for response from server…"
        case .completed(let destinationLocation, let error):
            if let error = error {
                return "Error: \(error.localizedDescription)"
            } else if destinationLocation != nil {
                if download.isFinishedProcessing {
                    return "Finished"
                } else {
                    return "Installing…"
                }
            }
        default:
            break
        }
        return ""
    }
    
    private var isFailed: Bool {
        switch download.downloadProgress {
        case .completed(_, let urlError):
            return urlError != nil
        default:
            return false
        }
    }
    
    private var fractionCompleted: Double {
        if download.isFinishedProcessing {
            return 1.0
        }
        switch download.downloadProgress {
        case .downloading(let progress):
            return progress.fractionCompleted
        case .completed(let destinationLocation, let error):
            return destinationLocation != nil && error == nil ? 1.0 : 0
        default:
            return 0
        }
    }
    
    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if download.isFinishedProcessing {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
                    .font(.title)
            } else {
                if isFailed {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(.red)
                        .font(.title)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.75, anchor: .center)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(download.isActive ? "Downloading " : "")\(download.name)")
                    .font(.callout)
                ProgressView(value: fractionCompleted)
                    .progressViewStyle(.linear)
                    .frame(height: 5)
                    .clipShape(Capsule())
                Text(statusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(isFailed ? .red : .secondary)
            }
            .font(.callout)
            if isFailed {
                Button("Retry") {
                    retryAction()
                }
                .buttonStyle(.borderedProminent)
            }
            if download.isFinishedProcessing && !isFailed {
                Menu {
                    Button("Re-download") {
                        redownloadAction()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
    
    public init(download: Downloadable, retryAction: @escaping (() -> Void), redownloadAction: @escaping (() -> Void)) {
        self.download = download
        self.retryAction = retryAction
        self.redownloadAction = redownloadAction
    }
}

public struct ActiveDownloadsList: View {
    @ObservedObject private var downloadController = DownloadController.shared
    
    public var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(downloadController.unfinishedDownloads) { download in
                    DownloadProgress(download: download, retryAction: {
                        Task { @MainActor in
                            await downloadController.ensureDownloaded([download])
                        }
                    }, redownloadAction: {
                        downloadController.download(download)
                    })
                    .padding(.horizontal, 12)
                    Divider()
                        .padding(.horizontal, 6)
                }
            }
        }
    }
    
    public init() {
    }
}

public struct ActiveDownloadsBox: View {
    let title: String
    
    @ScaledMetric(relativeTo: .body) private var listHeight = 105
    
    @AppStorage("ActiveDownloadsBox.isExpanded") private var isExpanded = true
    
    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ActiveDownloadsList()
                    .frame(maxHeight: listHeight)
                Spacer(minLength: 0)
            }
        } label: {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.75, anchor: .center)
                Text(title)
                    .font(.headline)
                    .bold()
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 10)
    }
    
    public init(title: String) {
        self.title = title
    }
}

public struct DownloadProgressView: View {
    private let size: CGFloat // Size parameter for circle, path, and stop image
    @ObservedObject private var downloadable: Downloadable
    @Binding var downloadURLs: [String]

    public init(size: CGFloat, downloadable: Downloadable, downloadURLs: Binding<[String]>) {
        self.size = size
        self.downloadable = downloadable
        _downloadURLs = downloadURLs
    }

    public var body: some View {
        InnerDownloadProgressView(size: size, url: downloadable.url, fractionCompleted: downloadable.fractionCompleted, downloadURLs: $downloadURLs)
    }
}

public struct DownloadButton: View {
    @ObservedObject var downloadable: Downloadable
    @Binding var downloadURLs: [String]
    
    public init(downloadable: Downloadable, downloadURLs: Binding<[String]>) {
        self.downloadable = downloadable
        _downloadURLs = downloadURLs
    }
    
    public var body: some View {
        Group {
            if #available(macOS 14, iOS 16, *) {
                Button(action: {
                    downloadURLs = Array(Set(downloadURLs).union(Set([downloadable.id])))
                }) {
                    Text("Download")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            } else {
                Button(action: {
                    downloadURLs = Array(Set(downloadURLs).union(Set([downloadable.id])))
                }) {
                    Text("Download")
                }
                .buttonStyle(.borderedProminent)
            }
        }
//#if os(iOS)
//        .textCase(.uppercase)
//#endif
    }
}

struct CancelDownloadButton: View {
    @ObservedObject var downloadable: Downloadable
    @Binding var downloadURLs: [String]
    
    public init(downloadable: Downloadable, downloadURLs: Binding<[String]>) {
        self.downloadable = downloadable
        _downloadURLs = downloadURLs
    }
    
    public var body: some View {
        Button(role: .cancel, action: {
            Task { @MainActor in
                downloadURLs = Array(Set(downloadURLs).subtracting(Set([downloadable.url.absoluteString])))
                await DownloadController.shared.cancelInProgressDownloads(matchingDownloadURL: downloadable.url)
            }
        }) {
            Text("Cancel")
        }
        .buttonStyle(.borderless)
    }
}
    
public struct FailureMessagesButton: View {
    var messages: [String]?
    
    public init(messages: [String]? = nil) {
        self.messages = messages
    }
    
    public var body: some View {
        Group {
            if let messages = messages, !messages.isEmpty {
                Menu {
                    ForEach(messages, id: \.self) { message in
                        Text(message)
                    }
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }
}

struct InnerDownloadProgressView: View {
    let size: CGFloat // Size parameter for circle, path, and stop image
    let url: URL
    let fractionCompleted: Double
    @Binding var downloadURLs: [String]

    public var body: some View {
        Button(action: {
            Task {
                downloadURLs = Array(Set(downloadURLs).subtracting(Set([url.absoluteString])))
                await DownloadController.shared.cancelInProgressDownloads(matchingDownloadURL: url)
            }
        }) {
            ZStack {
                Color.init(white: 1, opacity: 0.00000000001) // Clickability
                
                let radius = size / 2 - size / 20
                Path { path in
                    path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: radius, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 360), clockwise: false)
                }
                .stroke(style: StrokeStyle(lineWidth: size / 7, lineCap: .round, lineJoin: .round))
                .foregroundColor(.gray)
                .opacity(0.5)
                .frame(width: size, height: size) // Use the size parameter

                Path { path in
                    let startAngle = Angle(degrees: 0)
                    let endAngle = Angle(degrees: Double(360 * min(fractionCompleted, 1.0)))
                    path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                }
                .stroke(style: StrokeStyle(lineWidth: size / 7, lineCap: .round, lineJoin: .round))
                .foregroundColor(.accentColor)
                .frame(width: size, height: size) // Use the size parameter
                .rotationEffect(Angle(degrees: -90))
                .animation(.linear)

//                Image(systemName: "stop.fill")
//                    .resizable()
//                    .aspectRatio(contentMode: .fit)
//                    .padding(8)
            }
            .frame(width: size, height: size) // Use the size parameter
        }
        .buttonStyle(.plain)
    }
}

public struct DownloadControls: View {
    @ObservedObject var downloadable: Downloadable
    @Binding var downloadURLs: [String]
    
    @ObservedObject private var downloadController = DownloadController.shared
    @ScaledMetric(relativeTo: .callout) private var downloadProgressSize: CGFloat = 20
    
    public init(downloadable: Downloadable, downloadURLs: Binding<[String]>) {
        self.downloadable = downloadable
        _downloadURLs = downloadURLs
    }
    
    public var body: some View {
        Group {
            if let humanizedFileSize = downloadable.humanizedFileSize {
                Text(humanizedFileSize)
                    .bold()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if downloadable.isActive {
                DownloadProgressView(size: downloadProgressSize, downloadable: downloadable, downloadURLs: $downloadURLs)
                CancelDownloadButton(downloadable: downloadable, downloadURLs: $downloadURLs)
            } else if downloadable.isFinishedDownloading {
                modelDeleteButton
            } else {
                DownloadButton(downloadable: downloadable, downloadURLs: $downloadURLs)
                //                    .onChange(of: viewModel.selectedDownloadable) { downloadable in
                //                    }
                
                FailureMessagesButton(messages: downloadController.failureMessages)
            }
        }
    }
    
    private var modelDeleteButton: some View {
        Button {
            downloadURLs = Array(Set(downloadURLs).subtracting(Set([downloadable.url.absoluteString])))
            Task { try? await downloadController.delete(download: downloadable) }
        } label: {
            Image(systemName: "trash")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
    }
}
//struct DownloadProgressView_Previews: PreviewProvider {
//    static var previews: some View {
//        Text("hi")
////            .previewLayout(.sizeThatFits)
//    }
//}
//
//#Preview {
//    Text("hiuyiui2")
//}
//#Preview("Download in Progress") {
////    InnerDownloadProgressView(size: 100, url: URL(string: "https://example.example")!, fractionCompleted: 0.6)
//    Text("hiuyiui")
//}
