import AppKit
import SwiftUI

/// Subtle kraft-paper grain for the window background: soft cellulose mottling, fine grain and loose fibers.
/// Generated once as a seamless tile; SwiftUI then just tiles the cached image.
enum PaperTexture {
    static let tileSize = 768
    static let scale: CGFloat = 2

    static let image: NSImage = {
        let cgImage = makeTile()
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(tileSize) / scale, height: CGFloat(tileSize) / scale))
    }()

    static func makeTile(seed: UInt64 = 0xACE27) -> CGImage {
        let size = tileSize
        var rng = SplitMix(seed: seed)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)

        // Soft mottling: tileable value noise in two octaves, plus per-pixel grain.
        let coarse = ValueNoise(cells: 6, rng: &rng)
        let medium = ValueNoise(cells: 24, rng: &rng)
        for y in 0..<size {
            for x in 0..<size {
                let u = Double(x) / Double(size), v = Double(y) / Double(size)
                let mottling = coarse.sample(u, v) * 0.55 + medium.sample(u, v) * 0.45
                let grain = rng.nextDouble() * 2 - 1
                let value = mottling * 0.42 + grain * 0.45
                write(value, at: (y * size + x) * 4, into: &pixels)
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        // Loose fibers, mostly darker strands with a few pale ones, wrapped so the tile stays seamless.
        context.setLineCap(.round)
        for index in 0..<900 {
            let dark = index % 5 != 0
            let start = CGPoint(x: rng.nextDouble() * Double(size), y: rng.nextDouble() * Double(size))
            let length = 3 + pow(rng.nextDouble(), 2.6) * 20
            var angle = rng.nextDouble() * .pi * 2
            let bend = (rng.nextDouble() - 0.5) * 0.16
            let path = CGMutablePath()
            path.move(to: start)
            var point = start
            for _ in 0..<4 {
                angle += bend
                point.x += cos(angle) * length / 4
                point.y += sin(angle) * length / 4
                path.addLine(to: point)
            }
            let alpha = 0.08 + rng.nextDouble() * 0.2
            context.setStrokeColor(dark
                ? CGColor(srgbRed: 0.33, green: 0.24, blue: 0.15, alpha: alpha)
                : CGColor(srgbRed: 1, green: 0.99, blue: 0.96, alpha: alpha * 1.4))
            context.setLineWidth(0.5 + rng.nextDouble() * 0.7)
            for dx in [-size, 0, size] {
                for dy in [-size, 0, size] {
                    var shift = CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))
                    guard let shifted = path.copy(using: &shift) else { continue }
                    context.addPath(shifted)
                    context.strokePath()
                }
            }
        }

        // Tiny specks of bark, like the flecks in unbleached kraft.
        for _ in 0..<420 {
            let rect = CGRect(x: rng.nextDouble() * Double(size), y: rng.nextDouble() * Double(size),
                              width: 0.7 + rng.nextDouble() * 1.4, height: 0.7 + rng.nextDouble() * 1.4)
            context.setFillColor(CGColor(srgbRed: 0.3, green: 0.21, blue: 0.13, alpha: 0.12 + rng.nextDouble() * 0.28))
            context.fillEllipse(in: rect)
        }

        return context.makeImage()!
    }

    /// Negative values darken with a warm brown, positive values lighten; stored premultiplied.
    private static func write(_ value: Double, at offset: Int, into pixels: inout [UInt8]) {
        let (r, g, b, a): (Double, Double, Double, Double) = value < 0
            ? (0.36, 0.27, 0.17, min(1, -value) * 0.22)
            : (1, 0.99, 0.95, min(1, value) * 0.28)
        pixels[offset] = UInt8(r * a * 255)
        pixels[offset + 1] = UInt8(g * a * 255)
        pixels[offset + 2] = UInt8(b * a * 255)
        pixels[offset + 3] = UInt8(a * 255)
    }

    private struct ValueNoise {
        let cells: Int
        let values: [Double]

        init(cells: Int, rng: inout SplitMix) {
            self.cells = cells
            values = (0..<(cells * cells)).map { _ in rng.nextDouble() * 2 - 1 }
        }

        func sample(_ u: Double, _ v: Double) -> Double {
            let x = u * Double(cells), y = v * Double(cells)
            let x0 = Int(x), y0 = Int(y)
            let fx = smooth(x - Double(x0)), fy = smooth(y - Double(y0))
            func at(_ i: Int, _ j: Int) -> Double { values[(j % cells) * cells + (i % cells)] }
            let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * fx
            let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * fx
            return top + (bottom - top) * fy
        }

        private func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func nextDouble() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}

/// The window background: the panel color with the paper grain tiled on top.
struct PaperBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.panelBackground
            .overlay {
                Image(nsImage: PaperTexture.image)
                    .resizable(resizingMode: .tile)
                    .opacity(colorScheme == .dark ? 0.35 : 0.7)
                    .blendMode(colorScheme == .dark ? .plusLighter : .normal)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
