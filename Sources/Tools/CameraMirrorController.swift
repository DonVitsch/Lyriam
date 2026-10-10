import AppKit
import AVFoundation
import Combine

/// The camera is a temporary mirror. Merely visiting the page never opens it.
@MainActor
final class CameraMirrorController: ObservableObject {
    enum Status: Equatable {
        case off, requesting, starting, running, denied, unavailable, failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var cameraName = "Camera"
    let session: AVCaptureSession

    private let worker: MirrorCaptureWorker
    private var pageVisible = false
    private var screenLocked = false
    private var requestGeneration = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let worker = MirrorCaptureWorker()
        self.worker = worker
        session = worker.session
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .running || self.status == .starting else { return }
                self.stop()
                self.status = .failed("The camera became unavailable. Try again when it is free.")
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .running || self.status == .starting else { return }
                self.stop()
                self.status = .failed("Camera interrupted. Close other camera apps and try again.")
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        worker.stop()
    }

    func setPageVisible(_ visible: Bool) {
        pageVisible = visible
        if !visible { stop() }
    }

    func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        if locked { stop() }
    }

    /// This is called exclusively by the explicit Enable Camera / Try Again button.
    func enable() {
        guard pageVisible, !screenLocked,
              status != .running, status != .starting, status != .requesting else { return }
        requestGeneration += 1
        let generation = requestGeneration
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start(generation: generation)
        case .notDetermined:
            status = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.requestGeneration == generation,
                          self.pageVisible, !self.screenLocked else { return }
                    if granted { self.start(generation: generation) }
                    else { self.status = .denied }
                }
            }
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .unavailable
        }
    }

    func stop() {
        requestGeneration += 1
        worker.stop()
        status = .off
    }

    func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    private func start(generation: Int) {
        guard pageVisible, !screenLocked, requestGeneration == generation else { return }
        status = .starting
        worker.start { [weak self] result in
            Task { @MainActor in
                guard let self, self.requestGeneration == generation,
                      self.pageVisible, !self.screenLocked else { return }
                switch result {
                case .success(let name):
                    self.cameraName = name
                    self.status = .running
                case .failure(let error):
                    self.status = error == .noDevice ? .unavailable : .failed(error.description)
                }
            }
        }
    }
}

/// All session mutations are serialized away from the UI thread. A stop also
/// invalidates pending configuration immediately, including permission races.
private final class MirrorCaptureWorker: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noDevice, inputRejected, couldNotStart
        var description: String {
            switch self {
            case .noDevice: return "未连接摄像头。"
            case .inputRejected: return "摄像头暂时无法开启。"
            case .couldNotStart: return "摄像头未能启动，请关闭其他使用摄像头的应用后重试。"
            }
        }
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.local.lyriam.mirror", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0

    func start(completion: @escaping (Result<String, Failure>) -> Void) {
        lock.lock()
        generation += 1
        let token = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(token) else { return }
            guard let device = AVCaptureDevice.default(for: .video) else {
                completion(.failure(.noDevice)); return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard isCurrent(token) else { return }
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    completion(.failure(.inputRejected)); return
                }
                session.addInput(input)
                session.commitConfiguration()
                guard isCurrent(token) else {
                    releaseInputs(); return
                }
                session.startRunning()
                guard isCurrent(token) else {
                    session.stopRunning(); releaseInputs(); return
                }
                if session.isRunning { completion(.success(device.localizedName)) }
                else { releaseInputs(); completion(.failure(.couldNotStart)) }
            } catch {
                completion(.failure(.inputRejected))
            }
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        lock.unlock()
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            releaseInputs()
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }

    private func releaseInputs() {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
    }
}
