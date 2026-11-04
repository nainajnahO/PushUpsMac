import SwiftUI

// What's drawn on the athlete, frame by frame: the near arm and the body line over a dashed straight
// reference, or the whole skeleton under the body line.

/// How much of the body the overlay draws.
public enum OverlayStyle: String, Codable, Sendable, CaseIterable {
    /// Only what's measured: the near arm, and the body line in place of the torso and leg.
    case near
    /// The whole skeleton, both sides, with the body line over it.
    case full
}

/// Which way the hips are off the line, when the body line is past the back tolerance.
public enum Bend: Sendable, Equatable {
    case hipsLow, hipsHigh

    public var label: String { self == .hipsLow ? "Hips low" : "Hips high" }
}

/// What the overlay draws on one frame.
public struct OverlayFrame: Sendable, Equatable {
    /// The athlete's joints, normalized to the frame with y down.
    public var joints: [JointName: CGPoint]
    public var side: Side
    /// Nil while the body line is within tolerance on this frame (or unseen).
    public var bend: Bend?
}

extension RepCounter {
    /// The frame on screen `time` seconds into the clip: the last one shown by then, or the first.
    public func frame(at time: Double) -> Int {
        times.lastIndex { $0 <= time } ?? 0
    }

    /// The overlay on frame `frame`: its athlete, or the last one seen within 2 frames, and which way the
    /// body line is bent past `tolerance` degrees there, if it is.
    public func overlay(atFrame frame: Int, tolerance: Double) -> OverlayFrame? {
        guard poses.indices.contains(frame),
              let held = stride(from: frame, through: max(0, frame - 2), by: -1).first(where: { !poses[$0].joints.isEmpty })
        else { return nil }
        let reading = line[frame]
        let bend: Bend? = reading.isFinite && abs(reading) > tolerance ? (reading < 0 ? .hipsLow : .hipsHigh) : nil
        return OverlayFrame(joints: poses[held].joints.mapValues(\.location), side: side ?? confidence.surer,
                            bend: bend)
    }
}

/// The overlay, drawn over a frame of the view's size, in system colours. A bent back shows red, dashed and
/// labelled at the hip, so it doesn't rest on colour alone.
public struct OverlayView: View {
    public var frame: OverlayFrame
    public var style: OverlayStyle

    public init(frame: OverlayFrame, style: OverlayStyle) {
        self.frame = frame
        self.style = style
    }

    /// The skeleton without the face, and the colour of each edge: an arm, a leg, the torso.
    nonisolated static let edges: [(JointName, JointName, Color)] = [
        (.leftAnkle, .leftKnee, .purple), (.leftKnee, .leftHip, .purple),
        (.rightAnkle, .rightKnee, .brown), (.rightKnee, .rightHip, .brown),
        (.leftHip, .rightHip, .gray), (.leftShoulder, .leftHip, .gray), (.rightShoulder, .rightHip, .gray),
        (.leftShoulder, .rightShoulder, .gray),
        (.leftShoulder, .leftElbow, .cyan), (.leftElbow, .leftWrist, .cyan),
        (.rightShoulder, .rightElbow, .indigo), (.rightElbow, .rightWrist, .indigo),
    ]

    public var body: some View {
        Canvas { context, size in
            let width: CGFloat = 4, radius: CGFloat = 4
            let point = { (name: JointName) in frame.joints[name].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } }
            func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat, dash: [CGFloat] = []) {
                context.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(color),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            }
            func joint(_ p: CGPoint) {
                let dot = CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)
                context.fill(Path(ellipseIn: dot), with: .color(.white))
                context.stroke(Path(ellipseIn: dot.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.6)), lineWidth: 1)
            }

            if style == .full {
                for (a, b, color) in Self.edges {
                    if let p = point(a), let q = point(b) { line(p, q, color, width) }
                }
                for name in Side.left.joints + Side.right.joints { if let p = point(name) { joint(p) } }
            }
            // The body line, over a dashed straight shoulder-to-ankle reference: the gap between the two is how
            // far the hips are off straight. Light dashes on a dark edge, so they read on a light wall and on a
            // dark floor.
            let near = frame.side.joints   // shoulder, elbow, wrist, hip, knee, ankle
            if let s = point(near[0]), let hip = point(near[3]), let a = point(near[5]) {
                line(s, a, .black.opacity(0.6), 5, dash: [6, 6])
                line(s, a, .white, 2, dash: [6, 6])
                let color: Color = frame.bend == nil ? .green : .red
                let dash: [CGFloat] = frame.bend == nil ? [] : [10, 5]
                line(s, hip, color, width + 1, dash: dash)
                line(hip, a, color, width + 1, dash: dash)
                if let bend = frame.bend {
                    let label = context.resolve(Text(bend.label).font(.callout.weight(.semibold)).foregroundStyle(.white))
                    let size = label.measure(in: CGSize(width: 400, height: 100))
                    // Under the hip when they're low, over it when they're high.
                    let y = hip.y + (bend == .hipsLow ? 1 : -1) * (size.height + 16)
                    let box = CGRect(x: hip.x - size.width / 2 - 8, y: y - size.height / 2 - 4,
                                     width: size.width + 16, height: size.height + 8)
                    context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(.red))
                    context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
                }
            }
            if style == .near {
                let arm: Color = frame.side == .left ? .cyan : .indigo
                for (u, v) in [(near[0], near[1]), (near[1], near[2])] {
                    if let p = point(u), let q = point(v) { line(p, q, arm, width + 1) }
                }
                for name in [near[0], near[1], near[2], near[3], near[5]] { if let p = point(name) { joint(p) } }
            }
        }
    }
}
