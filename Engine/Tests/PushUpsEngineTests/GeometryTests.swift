import Testing
@testable import PushUpsEngine

/// Side, arm length and the raw shoulder height, body line and elbow series against the demo's,
/// on the same keypoints.
@Test(arguments: goldenCases)
func geometryMatchesPython(name: String, model: String) throws {
    let (poses, dump) = try loadCase(name, model)
    let (indices, frames) = poses.unwrapped()
    #expect(indices == dump.indices)
    #expect(frames.joined().count == poses.content.items.count - dump.dropped)
    let side = pickSide(frames)
    #expect(side.rawValue == dump.side)
    let joints = Joints(frames, side: side, aspect: Double(poses.video.width) / Double(poses.video.height))
    let arm = armLength(joints)
    let raw = shoulderHeight(joints, arm: arm)
    let line = bodyLine(joints)
    let elbow = angle(joints.shoulder, joints.elbow, joints.wrist)
    let differences = [abs(arm - dump.arm!), maxDifference(raw, dump.raw), maxDifference(line, dump.line),
                       maxDifference(elbow, dump.elbow)]
    print("\(name): side \(side), arm \(sci(differences[0])), raw height \(sci(differences[1])), body line \(sci(differences[2])) °, elbow \(sci(differences[3])) °")
    #expect(differences.allSatisfy { $0 <= tolerance }, "\(differences)")
}
