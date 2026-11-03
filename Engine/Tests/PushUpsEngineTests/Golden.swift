import Foundation
import Testing
@testable import PushUpsEngine

/// A dump from `tools/golden.py`: the demo's own results on a poses JSON (see the script's docstring).
struct Dump: Decodable {
    struct Input: Decodable {
        let poses: String
        let fps: Double
        let width: Int
        let height: Int
        let aspect: Double
        let n_frames: Int
        let source: String
    }
    struct Rep: Decodable {
        struct Grade: Decodable {
            let bottom_height: Double?, top_height: Double?, top_required: Double?, back_worst: Double?
            let bottom_elbow: Double?, top_elbow: Double?
            let bottom_ok: Bool, top_ok: Bool, back_ok: Bool, complete: Bool
            let reason: String, back_label: String
        }
        let number: Int
        let frames: [String: Int]
        let times: [String: Double]
        let depth: Double?
        let eccentric_seconds: Double, pause_seconds: Double, concentric_seconds: Double, ascent_seconds: Double
        let grade: Grade?
    }
    let input: Input
    let dropped: Int
    let indices: [Int]
    let times: [Double?]
    let side: String
    let arm: Double?
    let raw: [Double?], line: [Double?], elbow: [Double?]
    let filled: [Double?], median: [Double?], height: [Double?]
    let top: Double?
    let depth: [Double?]
    let amplitude: Double?
    let rise: [Double?]
    let cycles: [[Int]]
    let reps: [Rep]
    let tally: [Int]
    let reps_json: String, summary_txt: String, summary_csv: String, frames_csv: String
}

/// Every golden case: the hand-made figure, and Vision's poses on each test clip.
let goldenCases = [("synthetic", "handmade")] + clipNames.map { ($0, "vision") }

func loadCase(_ name: String, _ model: String) throws -> (Poses, Dump) {
    let poses = try Poses(contentsOf: golden(name, "poses-\(model).json"))
    let dump = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: golden(name, "python-\(model).json")))
    return (poses, dump)
}

/// The largest difference between a Swift series and Python's, where both are finite; infinity
/// if one is NaN where the other isn't (Python's `null`).
func maxDifference(_ swift: [Double], _ python: [Double?]) -> Double {
    guard swift.count == python.count else { return .infinity }
    return zip(swift, python).reduce(0) { worst, pair in
        switch (pair.0.isFinite, pair.1) {
        case (true, let p?): max(worst, abs(pair.0 - p))
        case (false, nil): worst
        default: .infinity
        }
    }
}

/// The parity bar for per-frame series and numbers, both float64 (PLAN.md).
let tolerance = 1e-9

/// `value` in scientific notation, for the measured differences the tests print.
func sci(_ value: Double) -> String {
    value == 0 ? "0" : String(format: "%.1e", value)
}
