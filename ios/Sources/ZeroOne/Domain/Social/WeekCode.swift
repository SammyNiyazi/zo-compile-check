import Foundation

/// Proof 33 "Add a friend: the week code" (study 30 codes.js, v1.7). The member
/// number written as a training week: 7 days x 5 sets. A filled segment is 1, a
/// faint one 0. 35 segments = 1 1 0, then 24 bits of the number and a CRC-8, the
/// last 32 scrambled with a fixed mask. 01's camera reads it like a barcode:
/// scanlines at a few angles, three brightness levels, both directions, CRC checked.
/// Same algorithm as the design's decoder, so its QA screenshots stay valid.
enum WeekCode {
    static let segmentCount = 35
    static let segment = 12.0, height = 30.0, gap = 4.0, day = 14.0
    static let groupWidth = 5 * segment + 4 * gap
    static let totalWidth = 7 * groupWidth + 6 * day

    private static let mask: [Int] = bits(0x5A3C96E1, count: 32)

    static func bits(_ value: UInt32, count: Int) -> [Int] {
        (0 ..< count).map { Int((value >> UInt32(count - 1 - $0)) & 1) }
    }

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for byte in bytes {
            c ^= byte
            for _ in 0 ..< 8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
        }
        return c
    }

    /// The 35 segments for a member number (0 ... 16,777,215).
    static func segments(for number: Int) -> [Int] {
        let n = UInt32(truncatingIfNeeded: number) & 0xFF_FFFF
        let data: [UInt8] = [UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
        let body = (bits(n, count: 24) + bits(UInt32(crc8(data)), count: 8)).enumerated().map { $0.element ^ mask[$0.offset] }
        return [1, 1, 0] + body
    }

    /// Reads 35 segment values in either direction; nil unless the checksum matches.
    static func number(fromSegments bits: [Int]) -> Int? {
        guard bits.count == segmentCount else { return nil }
        for sequence in [bits, Array(bits.reversed())] where sequence[0] == 1 && sequence[1] == 1 && sequence[2] == 0 {
            let body = sequence.dropFirst(3).enumerated().map { $0.element ^ mask[$0.offset] }
            var n: UInt32 = 0
            for bit in body.prefix(24) { n = (n << 1) | UInt32(bit) }
            var c: UInt8 = 0
            for bit in body.suffix(8) { c = (c << 1) | UInt8(bit) }
            let data: [UInt8] = [UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
            if crc8(data) == c { return Int(n) }
        }
        return nil
    }

    // MARK: Decoding a line of brightness samples

    private static func kmeans3(_ s: [Double]) -> [Double]? {
        guard let lo = s.min(), let hi = s.max(), hi - lo >= 40 else { return nil }
        var c = [lo, (lo + hi) / 2, hi]
        for _ in 0 ..< 10 {
            var sum = [0.0, 0, 0], count = [0.0, 0, 0]
            for v in s {
                let k = nearest(v, c)
                sum[k] += v
                count[k] += 1
            }
            c = (0 ..< 3).map { count[$0] > 0 ? sum[$0] / count[$0] : c[$0] }
        }
        return c.sorted()
    }

    private static func nearest(_ v: Double, _ c: [Double]) -> Int {
        var best = 0
        for i in 1 ..< c.count where abs(v - c[i]) < abs(v - c[best]) { best = i }
        return best
    }

    private static func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }

    /// Runs decoder: segments and gaps from the run lengths.
    static func decodeRuns(_ s: [Double]) -> Int? {
        guard let c = kmeans3(s) else { return nil }
        let labels = s.map { nearest($0, c) }
        for background in [0, 2] {
            let full = 2 - background
            var runs: [(Character, Double)] = []
            for k in labels {
                let t: Character = k == background ? "B" : (k == full ? "F" : "E")
                if let last = runs.last, last.0 == t { runs[runs.count - 1].1 += 1 } else { runs.append((t, 1)) }
            }
            let marked = runs.filter { $0.0 != "B" }.map { $0.1 }.sorted()
            guard marked.count >= 20 else { continue }
            let w = marked[Int(Double(marked.count) * 0.75)]
            runs = runs.map { t, n in ((t == "E" && n < 0.55 * w) || (t == "F" && n < 0.35 * w)) ? ("B", n) : (t, n) }
            var merged: [(Character, Double)] = []
            for r in runs {
                if let last = merged.last, last.0 == r.0 { merged[merged.count - 1].1 += r.1 } else { merged.append(r) }
            }
            var segs: [(full: Bool, width: Double, gap: Double)] = []
            for (i, r) in merged.enumerated() where r.0 != "B" {
                let gap = i + 1 < merged.count && merged[i + 1].0 == "B" ? merged[i + 1].1 : 0
                segs.append((r.0 == "F", r.1, gap))
            }
            guard segs.count >= segmentCount else { continue }
            for a in 0 ... (segs.count - segmentCount) {
                let window = Array(segs[a ..< a + segmentCount])
                let sw = median(window.map { $0.width })
                if window.contains(where: { $0.width < 0.55 * sw || $0.width > 1.6 * sw }) { continue }
                if window.prefix(34).contains(where: { $0.gap == 0 || $0.gap > 1.6 * sw }) { continue }
                if let n = number(fromSegments: window.map { $0.full ? 1 : 0 }) { return n }
            }
        }
        return nil
    }

    /// Geometry decoder for small or far codes, when gaps blur: find both ends,
    /// then sample the 35 segment centres and 6 day gaps from the known layout.
    static func decodeGeometry(_ s: [Double]) -> Int? {
        guard let c = kmeans3(s) else { return nil }
        let n = s.count
        for bgIndex in [0, 2] {
            let bg = c[bgIndex], e = c[1], f = c[2 - bgIndex]
            let sign = f - bg >= 0 ? 1.0 : -1.0
            if abs(f - bg) < 60 || abs(e - bg) < 0.12 * abs(f - bg) { continue }
            func marked(_ v: Double) -> Bool { (v - (bg + (e - bg) * 0.3)) * sign > 0 }
            func clear(_ v: Double) -> Bool { (v - (bg + (e - bg) * 0.6)) * sign < 0 }
            func strong(_ v: Double) -> Bool { (v - (e + f) / 2) * sign > 0 }
            func at(_ x: Double) -> Double {
                let i = max(0, min(n - 2, Int(x.rounded(.down)))), fraction = x - Double(i)
                return s[i] * (1 - fraction) + s[i + 1] * fraction
            }
            var runs: [(Int, Int)] = []
            var start = -1
            for i in 0 ... n {
                let m = i < n && marked(s[i])
                if m && start < 0 { start = i } else if !m && start >= 0 { runs.append((start, i)); start = -1 }
            }
            for a in runs.indices {
                let q = runs[a].0
                guard [1, 2, 3].contains(where: { strong(s[min(n - 1, q + $0)]) }) else { continue }
                for b in a ..< runs.count {
                    let length = Double(runs[b].1 - runs[a].0)
                    if length < 70 || length > Double(n) * 0.98 { continue }
                    for d0 in [0, 0.5, -0.5, 1, -1] {
                        for d1 in [0, -0.5, 0.5, -1, 1, -1.5] {
                            let x0 = Double(runs[a].0) + d0, k = (length - d0 + d1) / totalWidth
                            var ok = true
                            for g in 0 ..< 6 where ok {
                                if !clear(at(x0 + (Double(g) * (groupWidth + day) + groupWidth + day / 2) * k)) { ok = false }
                            }
                            var bits: [Int] = []
                            for i in 0 ..< segmentCount where ok {
                                let g = Double(i / 5), p = Double(i % 5)
                                let v = at(x0 + (g * (groupWidth + day) + p * (segment + gap) + segment / 2) * k)
                                if !marked(v) { ok = false } else { bits.append(strong(v) ? 1 : 0) }
                            }
                            if ok, let number = number(fromSegments: bits) { return number }
                        }
                    }
                }
            }
        }
        return nil
    }

    static func decodeLine(_ s: [Double]) -> Int? { decodeRuns(s) ?? decodeGeometry(s) }

    /// A greyscale frame (row-major, one byte per pixel) -> member number, or nil.
    /// The geometry fallback runs only on a few rows, to keep each camera frame fast.
    static func decode(gray: [UInt8], width: Int, height: Int, rowStep: Int = 2) -> Int? {
        guard width > 70, height > 0, gray.count >= width * height else { return nil }
        func px(_ x: Double, _ y: Double) -> Double {
            let xi = max(0, min(width - 1, Int(x.rounded()))), yi = max(0, min(height - 1, Int(y.rounded())))
            return Double(gray[yi * width + xi])
        }
        for degrees in [0.0, -2, 2, -4, 4, -6, 6, -8, 8, -10, 10] {
            let t = tan(degrees * .pi / 180)
            for y0 in stride(from: 0, to: height, by: rowStep) {
                let line = (0 ..< width).map { px(Double($0), Double(y0) + (Double($0) - Double(width) / 2) * t) }
                if let n = decodeRuns(line) { return n }
                if y0 % (rowStep * 8) == 0, degrees == 0, let n = decodeGeometry(line) { return n }
            }
        }
        return nil
    }
}
