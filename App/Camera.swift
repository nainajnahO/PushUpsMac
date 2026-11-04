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

/// What the camera in use delivers: the frame as shown, in pixels, and its frame rate.
struct CameraFormat: Equatable, Sendable {
    var width: Int
    var height: Int
    var framesPerSecond: Double
}

/// The live camera: the cameras the Mac sees (an iPhone through Continuity Camera, the built-in camera,
/// external ones), the one in use, and AVFoundation's capture session showing it. Nothing here touches a
/// camera until ``turnOn()``, so opening the app or a clip never asks for camera access.
///
/// The camera in use follows `AVCaptureDevice.systemPreferredCamera`, which puts an iPhone first as it
/// appears, and the picker sets `userPreferredCamera`, as AVFoundation's header recommends.
@Observable
final class Camera {
    enum Status: Equatable {
        case off
        /// Asking for access, or starting the session.
        case starting
        /// Camera access is off for the app, in System Settings.
        case denied
        case noCamera
        case running
        case failed(String)
    }

    private(set) var status = Status.off
    /// The cameras the Mac sees now.
    private(set) var choices: [CameraChoice] = []
    /// The camera in use, by its `uniqueID`.
    private(set) var current: String?
    private(set) var format: CameraFormat?

    /// Made as the camera turns on, so nothing at launch touches AVFoundation's capture.
    @ObservationIgnored private(set) var capture: CaptureSession?
    @ObservationIgnored private var discovery: AVCaptureDevice.DiscoverySession?
    @ObservationIgnored private var devicesObservation: NSKeyValueObservation?
    @ObservationIgnored private var preferredObservation: PreferredCameraObserver?
    @ObservationIgnored private var runtimeErrors: (any NSObjectProtocol)?

    var isOn: Bool { status != .off }

    /// The camera in use, by name.
    var currentName: String? {
        choices.first { $0.id == current }?.name
    }

    /// Asks for camera access the first time, then shows the camera the Mac prefers, its frames going to
    /// `poser`.
    func turnOn(feeding poser: LivePoser) async {
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
        await capture.attach(poser)
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
                                                         mediaType: .video, position: .unspecified)
        self.discovery = discovery
        // Both are key-value observed on whichever thread AVFoundation changes them on.
        devicesObservation = discovery.observe(\.devices) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.devicesChanged() }
        }
        preferredObservation = PreferredCameraObserver { @Sendable [weak self] in
            Task { @MainActor in await self?.follow() }
        }
        runtimeErrors = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                               object: capture.session, queue: .main) { @Sendable [weak self] note in
            let error = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
            log.error("capture session error: \(error, privacy: .public)")
            Task { @MainActor in self?.status = .failed(error) }
        }
        devicesChanged()
        await follow()
    }

    /// Stops the session and lets go of the camera.
    func turnOff() {
        guard isOn else { return }
        status = .off
        (devicesObservation, preferredObservation, discovery) = (nil, nil, nil)
        if let runtimeErrors { NotificationCenter.default.removeObserver(runtimeErrors) }
        runtimeErrors = nil
        (choices, current, format) = ([], nil, nil)
        if let capture { Task { await capture.stop() } }
        capture = nil
        log.notice("camera off")
    }

    /// The picker's choice: the Mac's preferred camera from now on, which the session then follows.
    func select(_ id: String) {
        guard let device = discovery?.devices.first(where: { $0.uniqueID == id }) else { return }
        AVCaptureDevice.userPreferredCamera = device
        Task { await follow() }
    }

    private func devicesChanged() {
        guard let discovery else { return }
        choices = discovery.devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
        log.notice("cameras: \(self.choices.map(\.name).joined(separator: ", "), privacy: .public)")
    }

    /// Shows the Mac's preferred camera, if it isn't the one in use.
    private func follow() async {
        guard isOn, let capture else { return }
        guard let preferred = AVCaptureDevice.systemPreferredCamera else {
            status = .noCamera
            current = nil
            format = nil
            await capture.stop()
            return
        }
        let id = preferred.uniqueID
        guard id != current || status != .running else { return }
        current = id
        do {
            let format = try await capture.show(id)
            // Turned off, or moved on to another camera, meanwhile.
            guard isOn, current == id else { return }
            self.format = format
            status = .running
            log.notice("showing \(self.currentName ?? id, privacy: .public): \(format.width) × \(format.height) at \(format.framesPerSecond, format: .fixed(precision: 1)) fps")
        } catch {
            guard isOn, current == id else { return }
            status = .failed(error.localizedDescription)
            log.error("couldn't show \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    /// Sends every frame to `poser`, as 8-bit 4:2:0, the cameras' own format and Vision's. AVFoundation's
    /// late-frame dropping stays on, but the sink returns at once, so the dropping that counts is the poser's.
    func attach(_ poser: LivePoser) {
        let sink = FrameSink(poser: poser)
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
        session.beginConfiguration()
        if let old = self.input { session.removeInput(old) }
        guard session.canAddInput(input) else {
            if let old = self.input { session.addInput(old) }
            session.commitConfiguration()
            throw Failure.refused
        }
        session.addInput(input)
        session.commitConfiguration()
        self.input = input
        level(device)
        if !session.isRunning { session.startRunning() }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return CameraFormat(width: Int(dimensions.width), height: Int(dimensions.height),
                            framesPerSecond: 1 / device.activeVideoMinFrameDuration.seconds)
    }

    /// Turns and un-mirrors the frames Vision gets, as the preview is, and follows the rotation as it changes.
    private func level(_ device: AVCaptureDevice) {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
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
        }
        input = nil
    }
}

/// AVFoundation's delegate for the camera's frames: hands each one to Vision, on the frames' queue, and
/// returns at once.
private nonisolated final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let poser: LivePoser

    init(poser: LivePoser) {
        self.poser = poser
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Handed on whole: nothing here touches the buffer after this.
        nonisolated(unsafe) let frame = sampleBuffer
        poser.receive(CMReadySampleBuffer(unsafeWithPixelBuffer: frame))
    }
}

/// Hears `AVCaptureDevice.systemPreferredCamera` change. It's a class property, and Swift's `observe(_:)` only
/// takes an instance's key path, so this observes it the Objective-C way, on the class object.
private final class PreferredCameraObserver: NSObject {
    private let changed: @Sendable () -> Void

    init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        super.init()
        (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: "systemPreferredCamera", options: [.new], context: nil)
    }

    deinit {
        (AVCaptureDevice.self as AnyObject).removeObserver(self, forKeyPath: "systemPreferredCamera")
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changed()
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
