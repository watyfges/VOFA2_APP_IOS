import AppKit
import CoreGraphics

// Renders the 1024x1024 app icon: teal gradient, waveform and slider knob.
let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// Background gradient
let top = CGColor(red: 0.16, green: 0.55, blue: 0.57, alpha: 1)
let bottom = CGColor(red: 0.04, green: 0.16, blue: 0.20, alpha: 1)
if let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray,
                             locations: [0, 1]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])
}

// Waveform
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
context.setLineWidth(46)
context.setLineCap(.round)
context.setLineJoin(.round)
let left: CGFloat = 150
let right: CGFloat = 874
let mid: CGFloat = 620
let amplitude: CGFloat = 190
let steps = 160
context.beginPath()
for index in 0...steps {
    let t = CGFloat(index) / CGFloat(steps)
    let x = left + (right - left) * t
    let phase = t * .pi * 2 * 1.35
    let y = mid + sin(phase) * amplitude * (1 - 0.35 * t)
    if index == 0 { context.move(to: CGPoint(x: x, y: y)) } else { context.addLine(to: CGPoint(x: x, y: y)) }
}
context.strokePath()

// Slider track
let trackY: CGFloat = 300
let trackRect = CGRect(x: left, y: trackY - 18, width: right - left, height: 36)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
context.addPath(CGPath(roundedRect: trackRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
context.fillPath()

// Filled part
let knobX: CGFloat = left + (right - left) * 0.62
let filledRect = CGRect(x: left, y: trackY - 18, width: knobX - left, height: 36)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
context.addPath(CGPath(roundedRect: filledRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
context.fillPath()

// Knob
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fillEllipse(in: CGRect(x: knobX - 56, y: trackY - 56, width: 112, height: 112))
context.setFillColor(CGColor(red: 0.10, green: 0.42, blue: 0.45, alpha: 1))
context.fillEllipse(in: CGRect(x: knobX - 22, y: trackY - 22, width: 44, height: 44))

guard let image = context.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
