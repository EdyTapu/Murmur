import Foundation

/// Maps the helper's 10-dim gaze feature vector to a normalized screen point
/// (0...1, origin top-left) via ridge regression fitted during calibration.
///
/// Features are standardized (per-column mean/std from the calibration set)
/// before the fit - iris offsets live around ±0.15 while head translation is
/// tens of centimeters, and an unscaled ridge penalty would crush the iris
/// terms that carry the actual gaze signal. Quadratic iris terms soak up the
/// screen-edge nonlinearity a pure linear map misses.
struct GazeMapper: Codable, Equatable {
    var mean: [Double]
    var std: [Double]
    /// Weight vectors (bias first) over the standardized expanded features.
    var weightsX: [Double]
    var weightsY: [Double]

    static let rawDimension = 10

    static func expand(_ f: [Double]) -> [Double] {
        let ix = (f[0] + f[2]) / 2
        let iy = (f[1] + f[3]) / 2
        return f + [ix * ix, iy * iy, ix * iy]
    }

    func predict(_ rawFeatures: [Double]) -> CGPoint? {
        guard rawFeatures.count == Self.rawDimension else { return nil }
        let expanded = Self.expand(rawFeatures)
        guard expanded.count == mean.count else { return nil }
        var u = weightsX[0]
        var v = weightsY[0]
        for i in 0..<expanded.count {
            let z = (expanded[i] - mean[i]) / std[i]
            u += weightsX[i + 1] * z
            v += weightsY[i + 1] * z
        }
        return CGPoint(x: u, y: v)
    }

    /// Fit from calibration samples. Targets are normalized screen points.
    static func fit(
        features: [[Double]], targets: [CGPoint], lambda: Double = 2e-3
    ) -> GazeMapper? {
        guard features.count == targets.count, features.count >= 12,
            features.allSatisfy({ $0.count == rawDimension })
        else { return nil }

        let rows = features.map(expand)
        let d = rows[0].count
        let n = rows.count

        var mean = [Double](repeating: 0, count: d)
        for row in rows { for i in 0..<d { mean[i] += row[i] } }
        for i in 0..<d { mean[i] /= Double(n) }
        var std = [Double](repeating: 0, count: d)
        for row in rows {
            for i in 0..<d { std[i] += (row[i] - mean[i]) * (row[i] - mean[i]) }
        }
        for i in 0..<d { std[i] = max(sqrt(std[i] / Double(n)), 1e-6) }

        // Design matrix with a bias column, standardized.
        let dim = d + 1
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: dim), count: dim)
        var xtu = [Double](repeating: 0, count: dim)
        var xtv = [Double](repeating: 0, count: dim)
        var z = [Double](repeating: 0, count: dim)
        for (row, target) in zip(rows, targets) {
            z[0] = 1
            for i in 0..<d { z[i + 1] = (row[i] - mean[i]) / std[i] }
            for i in 0..<dim {
                for j in i..<dim { xtx[i][j] += z[i] * z[j] }
                xtu[i] += z[i] * Double(target.x)
                xtv[i] += z[i] * Double(target.y)
            }
        }
        for i in 0..<dim {
            for j in 0..<i { xtx[i][j] = xtx[j][i] }
            // Don't regularize the bias.
            if i > 0 { xtx[i][i] += lambda * Double(n) }
        }

        guard let wx = solve(xtx, xtu), let wy = solve(xtx, xtv) else { return nil }
        return GazeMapper(mean: mean, std: std, weightsX: wx, weightsY: wy)
    }

    /// Gaussian elimination with partial pivoting (the system is ~14x14).
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix
        var b = rhs
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<n where abs(a[row][col]) > abs(a[pivot][col]) {
                pivot = row
            }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            if pivot != col {
                a.swapAt(pivot, col)
                b.swapAt(pivot, col)
            }
            for row in (col + 1)..<n {
                let factor = a[row][col] / a[col][col]
                if factor == 0 { continue }
                for k in col..<n { a[row][k] -= factor * a[col][k] }
                b[row] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x
    }
}

/// A saved calibration: the fitted mapper plus the screen it maps onto,
/// in global CG (top-left origin) coordinates.
struct GazeCalibration: Codable, Equatable {
    var mapper: GazeMapper
    var screenRect: CGRect
    /// Median open-eye EAR measured during calibration; seeds the blink
    /// detector's baseline. Optional so pre-existing saves still decode.
    var openEAR: Double? = nil

    static func load() -> GazeCalibration? {
        guard let data = UserDefaults.standard.data(forKey: PrefKey.gazeCalibrationData)
        else { return nil }
        return try? JSONDecoder().decode(GazeCalibration.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: PrefKey.gazeCalibrationData)
        }
    }
}
