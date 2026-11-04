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
    /// The 17 COCO keypoints, normalized to the frame with y down; nil where unseen.
    public var keypoints: [CGPoint?]
    public var side: Side
    /// The body line within tolerance on this frame (or unseen): green, else red.
    public var straight: Bool
}

extension RepAnalysis {
    /// The source frame shown `time` seconds into the clip: frame index / fps, as the analysis
    /// times frames, clamped to the clip.
    public func sourceFrame(at time: Double, fps: Double) -> Int {
        let last = indices.last ?? 0
        return min(last, max(0, Int((time * fps).rounded(.down))))
    }

    /// The overlay on source frame `frame`: its athlete, or the last one seen within 2 frames (the
    /// demo's hold), and whether the body line is within `tolerance` degrees there.
    public func overlay(atSourceFrame frame: Int, tolerance: Double) -> OverlayFrame? {
        var athlete: Poses.Person?
        for held in stride(from: frame, through: max(0, frame - 2), by: -1) {
            if let i = indices.firstIndex(of: held), let person = athletes[i] {
                athlete = person
                break
            }
        }
        guard let athlete else { return nil }
        let reading = indices.firstIndex(of: frame).map { line[$0] } ?? .nan
        return OverlayFrame(
            keypoints: athlete.keypoints.map { $0 == [0, 0] ? nil : CGPoint(x: $0[0], y: $0[1]) },
            side: side, straight: !(reading.isFinite && abs(reading) > tolerance))
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
    nonisolated static let edges: [(Int, Int, String)] = [
        (15, 13, "left_leg"), (13, 11, "left_leg"), (16, 14, "right_leg"), (14, 12, "right_leg"),
        (11, 12, "torso"), (5, 11, "torso"), (6, 12, "torso"), (5, 6, "torso"),
        (5, 7, "left_arm"), (7, 9, "left_arm"), (6, 8, "right_arm"), (8, 10, "right_arm"),
    ]
    nonisolated static let ring = Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255)

    public var body: some View {
        Canvas { context, size in
            let scale = size.width / 720
            let thickness = max(1, (3 * scale).rounded())
            let radius = max(1, (4 * scale).rounded())
            let near = frame.side == .left ? 5 : 6
            let point = { (i: Int) in frame.keypoints[i].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } }
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
                for i in 5..<17 { if let p = point(i) { joint(p, ring: 1) } }
            }
            // The body line, over a dashed straight shoulder-to-ankle reference: the gap between the
            // two is how far the hips are off straight. A dark edge under the white dashes, so they
            // read on a light wall as on a dark floor.
            let body = max(2, thickness)
            if let s = point(near), let hip = point(near + 6), let a = point(near + 10) {
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
                for (u, v) in [(near, near + 2), (near + 2, near + 4)] {
                    if let p = point(u), let q = point(v) { line(p, q, arm, body) }
                }
                for i in [near, near + 2, near + 4, near + 6, near + 10] { if let p = point(i) { joint(p, ring: 1) } }
            }
        }
    }
}
