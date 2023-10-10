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
                        downloadController.ensureDownloaded([download])
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

fileprivate struct DownloadProgressView: View {
    var size: CGFloat // Size parameter for circle, path, and stop image
    var progress: Float
    var action: () async -> Void
    
    var body: some View {
        Button(action: {
            Task {
                await action()
            }
        }) {
            ZStack {
                Circle()
                    .stroke(Color.gray, lineWidth: 10)
                    .frame(width: size, height: size) // Use the size parameter
                
                Path { path in
                    let startAngle = Angle(degrees: 0)
                    let endAngle = Angle(degrees: Double(360 * min(progress, 1.0)))
                    
                    path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: size / 2 - 5, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                }
                .stroke(style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                .foregroundColor(.accentColor)
                .frame(width: size, height: size) // Use the size parameter
                .rotationEffect(Angle(degrees: -90))
                .animation(.linear)
                
                Image(systemName: "stop.fill")
                    .resizable()
                    .frame(width: size * 0.2, height: size * 0.2) // Use a fraction of the size parameter
                    .foregroundColor(.white)
                    .background(Color.red)
            }
        }
    }
}
