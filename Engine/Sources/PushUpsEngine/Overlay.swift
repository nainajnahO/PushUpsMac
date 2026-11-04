import SwiftUI

// What the demo's `render` draws on the athlete, frame by frame: the near arm and the body line
// over a dashed straight reference ("near"), or the whole skeleton under the body line ("full").

/// The demo's `OVERLAY`.
public enum OverlayStyle: String, Codable, Sendable, CaseIterable {
    /// Only what's measured: the near arm, and the body line in place of the torso and leg.
    case near
    /// The whole skeleton, both sides, with the body line over it.
    case full
}

/// What the overlay draws on one frame.
public struct OverlayFrame: Sendable, Equatable {
    /// The athlete's joints, normalized to the frame with y down.
    public var joints: [JointName: CGPoint]
    public var side: Side
    /// The body line within tolerance on this frame (or unseen): green, else red.
    public var straight: Bool
}

extension RepCounter {
    /// The frame on screen `time` seconds into the clip: the last one shown by then, or the first.
    public func frame(at time: Double) -> Int {
        times.lastIndex { $0 <= time } ?? 0
    }

    /// The overlay on frame `frame`: its athlete, or the last one seen within 2 frames, and whether the
    /// body line is within `tolerance` degrees there.
    public func overlay(atFrame frame: Int, tolerance: Double) -> OverlayFrame? {
        guard poses.indices.contains(frame),
              let held = stride(from: frame, through: max(0, frame - 2), by: -1).first(where: { !poses[$0].joints.isEmpty })
        else { return nil }
        let reading = line[frame]
        return OverlayFrame(joints: poses[held].joints.mapValues(\.location), side: side ?? pickSide(poses[...]),
                            straight: !(reading.isFinite && abs(reading) > tolerance))
    }
}

/// The overlay, drawn over a frame of the view's size, as the demo draws it on the video. Line
/// widths scale with the width, as the demo's do (3 px and 4 px dots at 720 wide).
public struct OverlayView: View {
    public var frame: OverlayFrame
    public var style: OverlayStyle

    public init(frame: OverlayFrame, style: OverlayStyle) {
        self.frame = frame
        self.style = style
    }

    // The demo's colours (`SKELETON_COLORS`, the panel's FULL and PARTIAL).
    nonisolated static let good = Color(red: 0x51 / 255, green: 0xcf / 255, blue: 0x66 / 255)
    nonisolated static let bad = Color(red: 0xff / 255, green: 0x6b / 255, blue: 0x6b / 255)
    nonisolated static let parts: [String: Color] = [
        "left_arm": Color(red: 0x22 / 255, green: 0xd3 / 255, blue: 0xee / 255),
        "right_arm": Color(red: 0x63 / 255, green: 0x66 / 255, blue: 0xf1 / 255),
        "left_leg": Color(red: 0xe8 / 255, green: 0x79 / 255, blue: 0xf9 / 255),
        "right_leg": Color(red: 0xfb / 255, green: 0x71 / 255, blue: 0x85 / 255),
        "torso": Color(red: 0xcb / 255, green: 0xd5 / 255, blue: 0xe1 / 255),
    ]
    /// The skeleton without the face, and the part each edge belongs to (the demo's `edge_part`).
    nonisolated static let edges: [(JointName, JointName, String)] = [
        (.leftAnkle, .leftKnee, "left_leg"), (.leftKnee, .leftHip, "left_leg"),
        (.rightAnkle, .rightKnee, "right_leg"), (.rightKnee, .rightHip, "right_leg"),
        (.leftHip, .rightHip, "torso"), (.leftShoulder, .leftHip, "torso"), (.rightShoulder, .rightHip, "torso"),
        (.leftShoulder, .rightShoulder, "torso"),
        (.leftShoulder, .leftElbow, "left_arm"), (.leftElbow, .leftWrist, "left_arm"),
        (.rightShoulder, .rightElbow, "right_arm"), (.rightElbow, .rightWrist, "right_arm"),
    ]
    nonisolated static let ring = Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255)

    public var body: some View {
        Canvas { context, size in
            let scale = size.width / 720
            let thickness = max(1, (3 * scale).rounded())
            let radius = max(1, (4 * scale).rounded())
            let point = { (name: JointName) in frame.joints[name].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } }
            func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat) {
                context.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(color),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            func joint(_ p: CGPoint, ring: CGFloat) {
                let dot = CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)
                context.fill(Path(ellipseIn: dot), with: .color(.white))
                context.stroke(Path(ellipseIn: dot.insetBy(dx: -ring, dy: -ring)), with: .color(Self.ring), lineWidth: 1)
            }

            if style == .full {
                for (a, b, part) in Self.edges {
                    if let p = point(a), let q = point(b) { line(p, q, Self.parts[part]!, thickness) }
                }
                for name in Side.left.joints + Side.right.joints { if let p = point(name) { joint(p, ring: 1) } }
            }
            // The body line, over a dashed straight shoulder-to-ankle reference: the gap between the
            // two is how far the hips are off straight. A dark edge under the white dashes, so they
            // read on a light wall as on a dark floor.
            let body = max(2, thickness)
            let near = frame.side.joints   // shoulder, elbow, wrist, hip, knee, ankle
            if let s = point(near[0]), let hip = point(near[3]), let a = point(near[5]) {
                let dash = max(2, (body * 2 / 3).rounded(.down))
                for k in stride(from: 0, to: 24, by: 2) {
                    let u = CGPoint(x: s.x + (a.x - s.x) * CGFloat(k) / 24, y: s.y + (a.y - s.y) * CGFloat(k) / 24)
                    let v = CGPoint(x: s.x + (a.x - s.x) * CGFloat(k + 1) / 24, y: s.y + (a.y - s.y) * CGFloat(k + 1) / 24)
                    line(u, v, Color(white: 30 / 255), dash + 3)
                    line(u, v, Color(white: 245 / 255), dash)
                }
                line(s, hip, frame.straight ? Self.good : Self.bad, body)
                line(hip, a, frame.straight ? Self.good : Self.bad, body)
            }
            if style == .near {
                let arm = Self.parts[frame.side == .left ? "left_arm" : "right_arm"]!
                for (u, v) in [(near[0], near[1]), (near[1], near[2])] {
                    if let p = point(u), let q = point(v) { line(p, q, arm, body) }
                }
                for name in [near[0], near[1], near[2], near[3], near[5]] { if let p = point(name) { joint(p, ring: 1) } }
            }
        }
    }
}
