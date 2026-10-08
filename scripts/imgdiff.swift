// Image difference for rtbench: PSNR and mean absolute error (0-255) between two images of the same size, over RGB.
// An optional crop (fraction of each edge) leaves out the window title bar and HUD edges.
// Usage: imgdiff A.png B.png [crop-fraction] [edge-fraction]   (prints: psnr_db mae)
// An edge fraction compares only the left and right strips that wide (where turning brings in new content).
import CoreGraphics
import Foundation
import ImageIO

func pixels(_ path: String) -> (Int, Int, [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, data)
}

let args = CommandLine.arguments
guard args.count >= 3, let a = pixels(args[1]), let b = pixels(args[2]), a.0 == b.0, a.1 == b.1 else {
    print("usage: imgdiff A.png B.png [crop] [edge]  (same-size images)")
    exit(2)
}
let crop = args.count > 3 ? Double(args[3]) ?? 0 : 0
let edge = args.count > 4 ? Double(args[4]) ?? 0 : 0
let (w, h) = (a.0, a.1)
let x0 = Int(Double(w) * crop), x1 = w - x0, y0 = Int(Double(h) * crop), y1 = h - y0
var sq = 0.0, abs = 0.0, n = 0.0
for y in y0..<y1 {
    for x in x0..<x1 {
        if edge > 0 && x >= Int(Double(w) * edge) && x < w - Int(Double(w) * edge) {
            continue
        }
        let i = (y * w + x) * 4
        for c in 0..<3 {
            let d = Double(a.2[i + c]) - Double(b.2[i + c])
            sq += d * d
            abs += Swift.abs(d)
            n += 1
        }
    }
}
let mse = sq / n
print(String(format: "%.2f %.3f", mse == 0 ? 99.0 : 10 * log10(255 * 255 / mse), abs / n))
