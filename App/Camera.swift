import AVFoundation
import Observation
import OSLog
import PushUpsEngine
import SwiftUI

nonisolated private let log = Logger(subsystem: "nainajnahO.PushUpsMac", category: "camera")

/// A camera the Mac sees, as the picker lists it.
struct CameraChoice: Identifiable, Hashable, Sendable {
    /// AVFoundation's `uniqueID`.
    let id: String
    let name: String
}

extension CameraChoice {
    init(_ device: AVCaptureDevice) {
        self.init(id: device.uniqueID, name: device.localizedName)
    }

    /// The camera picked last, kept across launches, with its name to show while it's away.
    /// `AVCaptureDevice.userPreferredCamera` can't say this: while the picked camera is away, it reports another.
    static var picked: CameraChoice? {
        get {
            guard let id = UserDefaults.standard.string(forKey: "cameraID"),
                  let name = UserDefaults.standard.string(forKey: "cameraName") else { return nil }
            return CameraChoice(id: id, name: name)
        }
        set {
            UserDefaults.standard.set(newValue?.id, forKey: "cameraID")
            UserDefaults.standard.set(newValue?.name, forKey: "cameraName")
        }
    }
}

/// What the camera in use delivers: the frame as shown, in pixels, and its frame rate.
struct CameraFormat: Equatable, Sendable {
    var width: Int
    var height: Int
    var framesPerSecond: Double
}

/// The live camera: the cameras the Mac sees (an iPhone through Continuity Camera, the built-in camera,
/// external ones), the one the set uses, and AVFoundation's capture session showing it. Nothing here touches
/// a camera until ``turnOn()``, so opening the app or a clip never asks for camera access.
///
/// A set holds one camera from start to end: the one picked last, or if none has been picked yet, the Mac's
/// own camera. Only the picker changes it. `AVCaptureDevice.systemPreferredCamera` isn't used: it "may change
/// spontaneously", and did mid-set (#82), and on macOS 27.2 it reads nil as the camera first turns on after
/// launch. While the held camera is away (not connected, or suspended), the set waits for it.
@Observable
final class Camera {
    enum Status: Equatable {
        case off
        /// Asking for access, or starting the session.
        case starting
        /// Camera access is off for the app, in System Settings.
        case denied
        /// No camera has been picked yet, and the Mac has none.
        case noCamera
        /// The held camera isn't connected, or is suspended: the set goes on once it's back.
        case waiting
        case running
        case failed(String)
    }

    private(set) var status = Status.off
    /// The camera the set uses.
    private(set) var held: CameraChoice?
    private(set) var format: CameraFormat?
    /// The cameras the Mac sees now.
    private var connected: [CameraChoice] = []

    /// Made as the camera turns on, so nothing at launch touches AVFoundation's capture.
    @ObservationIgnored private(set) var capture: CaptureSession?
    @ObservationIgnored private var discovery: AVCaptureDevice.DiscoverySession?
    @ObservationIgnored private var devicesObservation: NSKeyValueObservation?
    @ObservationIgnored private var suspensionObservation: NSKeyValueObservation?
    @ObservationIgnored private var runtimeErrors: (any NSObjectProtocol)?
    /// The camera the session shows, by its `uniqueID`.
    @ObservationIgnored private var shown: String?

    var isOn: Bool { status != .off }

    /// The cameras the Mac sees now, and the held one while it's away, as the picker lists them.
    var choices: [CameraChoice] {
        guard let held, !connected.contains(where: { $0.id == held.id }) else { return connected }
        return connected + [held]
    }

    /// Asks for camera access the first time, then shows the camera the set holds, its frames going to
    /// `poser`, and every one of them to `recorder`.
    func turnOn(feeding poser: LivePoser, recording recorder: LiveRecorder?) async {
        guard status == .off else { return }
        status = .starting
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .denied
                return
            }
        default:
            status = .denied
            return
        }
        // Turned off while the prompt was up.
        guard status == .starting else { return }

        let capture = CaptureSession()
        self.capture = capture
        await capture.attach(poser, recorder: recorder)
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
                                                         mediaType: .video, position: .unspecified)
        self.discovery = discovery
        // Key-value observed on whichever thread AVFoundation changes them on.
        devicesObservation = discovery.observe(\.devices) { @Sendable [weak self] _, _ in
            Task { @MainActor in await self?.devicesChanged() }
        }
        runtimeErrors = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                               object: capture.session, queue: .main) { @Sendable [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = error?.localizedDescription ?? "unknown error"
            log.error("capture session error: \(message, privacy: .public)")
            // The held camera unplugged: the device list changes too, and the set waits for it there.
            guard (error as? AVError)?.code != .deviceWasDisconnected else { return }
            Task { @MainActor in self?.status = .failed(message) }
        }
        held = CameraChoice.picked
        await devicesChanged()
    }

    /// Stops the session and lets go of the camera.
    func turnOff() {
        guard isOn else { return }
        status = .off
        (devicesObservation, suspensionObservation, discovery) = (nil, nil, nil)
        if let runtimeErrors { NotificationCenter.default.removeObserver(runtimeErrors) }
        runtimeErrors = nil
        (connected, held, shown, format) = ([], nil, nil, nil)
        if let capture { Task { await capture.stop() } }
        capture = nil
        log.notice("camera off")
    }

    /// The picker's choice: the set's camera from now on, and the first one of the next set.
    func select(_ id: String) {
        guard id != held?.id, let device = discovery?.devices.first(where: { $0.uniqueID == id }) else { return }
        let choice = CameraChoice(device)
        (CameraChoice.picked, held) = (choice, choice)
        log.notice("picked \(choice.name, privacy: .public) (\(choice.id, privacy: .public))")
        Task { await show() }
    }

    private func devicesChanged() async {
        guard let discovery else { return }
        connected = discovery.devices.map(CameraChoice.init)
        log.notice("cameras: \(self.connected.map(\.name).joined(separator: ", "), privacy: .public)")
        await show()
    }

    /// Shows the held camera, if it isn't showing; while it's away, the set waits for it. With none held (none
    /// picked yet), takes the Mac's own camera, or without one, the first there is, and holds it.
    private func show() async {
        guard isOn, let capture, let discovery else { return }
        if held == nil {
            let devices = discovery.devices
            held = (devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first).map(CameraChoice.init)
        }
        guard let held else {
            status = .noCamera
            return
        }
        guard let device = discovery.devices.first(where: { $0.uniqueID == held.id }), !device.isSuspended else {
            if status != .waiting { log.notice("waiting for \(held.name, privacy: .public) (\(held.id, privacy: .public))") }
            (status, format) = (.waiting, nil)
            return
        }
        guard held.id != shown || status != .running else { return }
        shown = held.id
        // Suspended, the camera stays listed but sends no frames: the set waits until it's back.
        suspensionObservation = device.observe(\.isSuspended) { @Sendable [weak self] device, _ in
            log.notice("\(device.localizedName, privacy: .public) \(device.isSuspended ? "suspended" : "back", privacy: .public)")
            Task { @MainActor in await self?.show() }
        }
        do {
            let format = try await capture.show(held.id)
            // Turned off, or moved on to another camera, meanwhile.
            guard isOn, self.held == held else { return }
            self.format = format
            status = .running
            log.notice("showing \(held.name, privacy: .public) (\(held.id, privacy: .public)): \(format.width) × \(format.height) at \(format.framesPerSecond, format: .fixed(precision: 1)) fps")
        } catch {
            guard isOn, self.held == held else { return }
            status = .failed(error.localizedDescription)
            log.error("couldn't show \(held.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// AVFoundation's capture session and its one camera input, on a queue of their own: starting and
/// reconfiguring the session block, and AVFoundation asks for them off the main thread. An actor run on
/// that queue, as Apple's AVCam sample has it.
actor CaptureSession {
    private let queue = DispatchSerialQueue(label: "nainajnahO.PushUpsMac.capture")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Read on the main actor only by the preview layer, which AVFoundation lets attach from any thread.
    nonisolated(unsafe) let session = AVCaptureSession()
    /// The camera shown, its device locked for configuration while it is (``show(_:)``).
    private var input: AVCaptureDeviceInput?
    /// The frames for Vision, on a queue of their own, so reconfiguring the session doesn't hold them up.
    private let output = AVCaptureVideoDataOutput()
    private let frames = DispatchQueue(label: "nainajnahO.PushUpsMac.frames", qos: .userInteractive)
    private var sink: FrameSink?
    /// Keeps the frames level with the horizon, as the preview is.
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    enum Failure: LocalizedError {
        case gone, refused

        var errorDescription: String? {
            switch self {
            case .gone: "The camera isn't connected anymore."
            case .refused: "The camera can't be used for capture."
            }
        }
    }

    /// Sends every frame to `recorder` and `poser`, as 8-bit 4:2:0, the cameras' own format and Vision's.
    /// AVFoundation's late-frame dropping stays on, but the sink returns at once, so the dropping that counts
    /// is the poser's.
    func attach(_ poser: LivePoser, recorder: LiveRecorder?) {
        let sink = FrameSink(poser: poser, recorder: recorder)
        self.sink = sink
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if output.availableVideoPixelFormatTypes.contains(format) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(sink, queue: frames)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    /// Shows the camera `id` in place of the one before, and starts the session if it isn't running.
    func show(_ id: String) throws -> CameraFormat {
        guard let device = AVCaptureDevice(uniqueID: id) else { throw Failure.gone }
        let input = try AVCaptureDeviceInput(device: device)
        let old = self.input
        // Locked while it's shown, once: on macOS the session puts an unlocked camera back in the session
        // preset's format (1080p), and macOS has no `.inputPriority` preset to keep the camera's own.
        let locking = device != old?.device
        if locking { try device.lockForConfiguration() }
        session.beginConfiguration()
        if let old { session.removeInput(old) }
        guard session.canAddInput(input) else {
            if let old { session.addInput(old) }
            session.commitConfiguration()
            if locking { device.unlockForConfiguration() }
            throw Failure.refused
        }
        session.addInput(input)
        if let format = Self.format720p(of: device) { device.activeFormat = format }
        session.commitConfiguration()
        if locking { old?.device.unlockForConfiguration() }
        self.input = input
        level(device)
        if !session.isRunning { session.startRunning() }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return CameraFormat(width: Int(dimensions.width), height: Int(dimensions.height),
                            framesPerSecond: 1 / device.activeVideoMinFrameDuration.seconds)
    }

    /// 1280 × 720 at 30 fps, where the camera has it, in place of the 1080p it starts in: the six clips count
    /// and grade the same, and a set records at less than half the size (#91). Set on the camera, as the
    /// session preset `.hd1280x720` isn't enough: under it, the iPhone went on sending 1080p. The iPhone has two
    /// 720p formats, up to 30 and up to 60 fps: the one up to 30.
    private static func format720p(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let fastest = { (format: AVCaptureDevice.Format) in
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        return device.formats
            .filter { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width == 1280 && size.height == 720
            }
            .min { fastest($0) < fastest($1) }
    }

    /// Turns and un-mirrors the frames Vision gets, as the preview is, and follows the rotation as it changes.
    private func level(_ device: AVCaptureDevice) {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            // AVFoundation's own mirroring off first: setting it while that's on throws.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        self.rotation = rotation
        // AVFoundation delivers its changes on the main queue: the turn is made back on this actor.
        rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) {
            @Sendable [weak self] rotation, _ in
            let angle = rotation.videoRotationAngleForHorizonLevelCapture
            Task { await self?.turn(to: angle) }
        }
    }

    private func turn(to angle: CGFloat) {
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        log.notice("frames turned \(angle, format: .fixed(precision: 0))°")
    }

    /// Stops the session and lets go of the camera.
    func stop() {
        if session.isRunning { session.stopRunning() }
        if let input {
            session.beginConfiguration()
            session.removeInput(input)
            session.commitConfiguration()
            input.device.unlockForConfiguration()
        }
        input = nil
    }
}

/// AVFoundation's delegate for the camera's frames: hands each one to the recording and to Vision, on the
/// frames' queue, and returns at once.
private nonisolated final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let poser: LivePoser
    let recorder: LiveRecorder?

    init(poser: LivePoser, recorder: LiveRecorder?) {
        (self.poser, self.recorder) = (poser, recorder)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Handed on whole: nothing here touches the buffer after this.
        nonisolated(unsafe) let buffer = sampleBuffer
        let frame = CMReadySampleBuffer(unsafeWithPixelBuffer: buffer)
        // Every frame into the recording, before Vision takes it or drops it.
        recorder?.append(frame)
        poser.receive(frame)
    }
}

/// The camera's live picture: AVFoundation's preview layer, fitted to the view as a clip is (aspect fit),
/// level with the horizon by AVFoundation's rotation coordinator, and not mirrored, so it shows what Vision
/// will see.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    /// The camera shown, by its `uniqueID`: each camera gets its own rotation.
    let cameraID: String?

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.cameraID != cameraID else { return }
        (coordinator.cameraID, coordinator.angle, coordinator.rotation) = (cameraID, nil, nil)
        guard let cameraID, let device = AVCaptureDevice(uniqueID: cameraID) else { return }
        if let connection = view.previewLayer.connection, connection.isVideoMirroringSupported {
            // AVFoundation mirrors a front camera's picture on its own, and setting it while it does throws.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: view.previewLayer)
        coordinator.rotation = rotation
        // AVFoundation delivers its changes on the main queue.
        coordinator.angle = rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { rotation, _ in
            let angle = rotation.videoRotationAngleForHorizonLevelPreview
            guard let connection = (rotation.previewLayer as? AVCaptureVideoPreviewLayer)?.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
            log.notice("preview turned \(angle, format: .fixed(precision: 0))°")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var cameraID: String?
        var rotation: AVCaptureDevice.RotationCoordinator?
        var angle: NSKeyValueObservation?
    }

    /// A view whose own layer is the preview layer.
    final class PreviewView: NSView {
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Not built from a nib") }

        override func makeBackingLayer() -> CALayer {
            let layer = AVCaptureVideoPreviewLayer()
            layer.backgroundColor = NSColor.black.cgColor
            return layer
        }
    }
}

extension Camera {
    /// The window's subtitle while the camera is on: what it delivers, and how much of it Vision poses.
    func subtitle(posedPerSecond: Double?) -> String {
        guard status == .running, let format else { return "" }
        let rate = { (fps: Double) in fps.formatted(.number.precision(.fractionLength(0))) }
        let posed = posedPerSecond.map { " · posing \(rate($0)) fps" } ?? ""
        return "\(format.width) × \(format.height) · \(rate(format.framesPerSecond)) fps" + posed
    }
}
