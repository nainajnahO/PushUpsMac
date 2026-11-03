// The rep signal's smoothing and its levels, as the demo's `src/reps.py` and `form.median_filter`
// compute them. The filters, the gap fill and the percentile are written here, not taken from
// Accelerate: NumPy's exact definitions decide the result, down to the order a sum is taken in,
// and nothing built in has them (edge padding, NaN-skipping medians, `np.interp`'s ends,
// `np.percentile`'s interpolation, `np.convolve`'s sums).

/// `np.pad(x, k / 2, mode="edge")`, with an even `k` bumped to the next odd size, as both filters do.
private func edgePadded(_ x: [Double], _ k: Int) -> (padded: [Double], k: Int) {
    let k = k + (k + 1) % 2
    guard let first = x.first, let last = x.last else { return (x, k) }
    let half = [Double](repeating: first, count: k / 2)
    return (half + x + [Double](repeating: last, count: k / 2), k)
}

/// The demo's `form.median_filter`: a centred running median of `k` frames that skips NaN, NaN only
/// where the whole window is (`np.nanmedian` over edge-padded windows).
func medianFilter(_ x: [Double], _ k: Int) -> [Double] {
    guard k >= 3 else { return x }
    let (padded, k) = edgePadded(x, k)
    return x.indices.map { i in median(padded[i..<(i + k)].filter { !$0.isNaN }) }
}

/// The demo's `_box_filter`: a centred moving average of `k` frames, edge-padded, so it doesn't
/// shift turnaround times: `np.convolve(pad, np.ones(k) / k, "valid")`.
///
/// Each window's sum is a fused multiply-add of its values in order, which is how NumPy's BLAS
/// `ddot` sums them: that reproduces all 3,204 windows of the golden dumps to the bit. Accelerate's
/// `vDSP.convolve` and its `cblas_ddot` each sum in another order and differ in the last bit,
/// which flips the counting's exact ties (a rep's start moved a frame on ViTPose's clean-left).
func boxFilter(_ x: [Double], _ k: Int) -> [Double] {
    guard k >= 2, !x.isEmpty else { return x }
    let (padded, k) = edgePadded(x, k)
    let weight = 1 / Double(k)
    return x.indices.map { i in
        padded[i..<(i + k)].reduce(0) { sum, value in sum.addingProduct(value, weight) }
    }
}

/// The demo's `_fill_gaps`: NaN filled by `np.interp` from the finite values around it, the ends
/// held at the nearest finite value. A series with no NaN, or nothing but NaN, has its NaN set to 0.
func fillGaps(_ x: [Double]) -> [Double] {
    let known = x.indices.filter { x[$0].isFinite }
    guard !known.isEmpty, known.count < x.count else { return x.map { $0.isFinite ? $0 : 0 } }
    var result = x
    var next = 0   // the first known index at or after i
    for i in x.indices {
        while next < known.count, known[next] < i { next += 1 }
        if next < known.count, known[next] == i { continue }
        if next == 0 {
            result[i] = x[known[0]]
        } else if next == known.count {
            result[i] = x[known[known.count - 1]]
        } else {
            // `np.interp`: slope × (x − xp[j]) + fp[j], the slope from the two known points around.
            let (a, b) = (known[next - 1], known[next])
            let slope = (x[b] - x[a]) / Double(b - a)
            result[i] = slope * Double(i - a) + x[a]
        }
    }
    return result
}

/// `np.percentile(x, q)` with its default linear method: the sorted values at (n − 1) × q / 100,
/// interpolated as NumPy's `_lerp` does (from the upper value when the fraction is 0.5 or more).
func percentile(_ x: [Double], _ q: Double) -> Double {
    guard !x.isEmpty else { return .nan }
    let sorted = x.sorted()
    let index = Double(sorted.count - 1) * (q / 100)
    let below = Int(index.rounded(.down))
    let above = Swift.min(below + 1, sorted.count - 1)
    let t = index - Double(below)
    let (a, b) = (sorted[below], sorted[above])
    let difference = b - a
    return t >= 0.5 ? b - difference * (1 - t) : a + difference * t
}

/// The demo's `_robust_depth`: the typical rep depth, as the median of the bottoms (local maxima of
/// depth past 30 % of the deepest), or the 95th percentile with fewer than three of them.
func robustDepth(_ depth: [Double]) -> Double {
    let top = depth.isEmpty ? 0 : depth.max()!
    guard top > 0 else { return 0 }
    let bottoms = depth.indices.dropFirst().dropLast().filter { i in
        depth[i] >= depth[i - 1] && depth[i] > depth[i + 1] && depth[i] > 0.3 * top
    }.map { depth[$0] }
    return bottoms.count >= 3 ? median(bottoms) : percentile(depth, 95)
}
