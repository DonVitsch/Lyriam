import AppKit
import AVFoundation
import SwiftUI

struct CameraMirrorView: View {
    @ObservedObject var controller: CameraMirrorController

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                if controller.status == .running {
                    MirrorCameraPreview(session: controller.session)
                } else {
                    VStack(spacing: 10) {
                        if controller.status == .starting || controller.status == .requesting {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "video.slash")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Text(previewLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            .frame(width: 520, height: 174)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topLeading) {
                if controller.status == .running {
                    Label("实时", systemImage: "circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(10)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("小镜子")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if controller.status == .running {
                        Button("关闭摄像头", action: controller.stop)
                            .buttonStyle(MirrorActionButtonStyle())
                    } else if controller.status == .denied {
                        Button("摄像头设置", action: controller.openCameraSettings)
                            .buttonStyle(MirrorActionButtonStyle())
                        Button("重试", action: controller.enable)
                            .buttonStyle(.plain).foregroundStyle(.white)
                    } else {
                        Button(action: controller.enable) {
                            Label("开启摄像头", systemImage: "video")
                        }
                        .buttonStyle(MirrorActionButtonStyle())
                        .disabled(controller.status == .starting || controller.status == .requesting)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                Text("镜像预览 · 不录制")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 174)
        .clipped()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { controller.setPageVisible(true) }
        .onDisappear { controller.setPageVisible(false) }
    }

    private var previewLabel: String {
        switch controller.status {
        case .requesting: return "等待摄像头授权"
        case .starting: return "正在开启摄像头…"
        case .denied: return "摄像头权限未开启"
        case .unavailable: return "未找到摄像头"
        case .failed: return "摄像头暂不可用"
        default: return "摄像头已关闭"
        }
    }

    private var detail: String {
        switch controller.status {
        case .running: return "\(controller.cameraName)\n离开此页或收起灵动岛后自动关闭。"
        case .denied: return "在系统设置中允许 Lyriam 使用摄像头后重试。"
        case .unavailable: return "连接摄像头后点击开启。"
        case .failed(let message): return message
        default: return "点击开启，快速整理仪容。收起、离开此页或锁屏后自动关闭。"
        }
    }
}

private struct MirrorActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.24 : 0.14),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct MirrorCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> MirrorPreviewNSView {
        let view = MirrorPreviewNSView()
        view.updateSession(session)
        return view
    }

    func updateNSView(_ nsView: MirrorPreviewNSView, context: Context) {
        nsView.updateSession(session)
    }

    static func dismantleNSView(_ nsView: MirrorPreviewNSView, coordinator: ()) {
        nsView.previewLayer.session = nil
    }
}

private final class MirrorPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(previewLayer)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    func updateSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session { previewLayer.session = session }
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}
