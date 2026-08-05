#!/usr/bin/env swift
//
// Renders the SameAge app icon: two photo ribbons of differing rhythm sharing one
// vertical axis — the whole idea of the app in one mark.
//
//   swift scripts/make_app_icon.swift App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// Fully opaque with no alpha channel, which the App Store requires of app icons.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

guard let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    // noneSkipLast = opaque; the App Store rejects icons with an alpha channel.
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("could not create bitmap context") }

func color(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}

// Deep near-black backdrop, matching the feed's own background.
context.setFillColor(color(0.055, 0.062, 0.078))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))

let margin: Double = 168
let gap: Double = 54
let columnWidth = (Double(side) - margin * 2 - gap) / 2
let radius: Double = 26

/// Draws one ribbon as a stack of rounded tiles. `heights` are relative weights, so the
/// two columns can carry visibly different rhythms while filling the same vertical span —
/// which is exactly what density scaling does in the app.
func drawRibbon(x: Double, heights: [Double], warm: Bool) {
    let spacing: Double = 20
    let available = Double(side) - margin * 2 - spacing * Double(heights.count - 1)
    let total = heights.reduce(0, +)

    var y = margin
    for (index, weight) in heights.enumerated() {
        let height = available * (weight / total)
        let rect = CGRect(x: x, y: Double(side) - y - height, width: columnWidth, height: height)

        // Shade down the column so the ribbon reads as receding into the past.
        let t = Double(index) / Double(max(heights.count - 1, 1))
        let fill = warm
            ? color(0.98 - 0.20 * t, 0.62 - 0.18 * t, 0.20 + 0.04 * t)
            : color(0.20 + 0.04 * t, 0.56 - 0.10 * t, 0.95 - 0.22 * t)

        context.setFillColor(fill)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
        context.fillPath()
        y += height + spacing
    }
}

// Left column: the older kid, denser early. Right: the younger, fewer and larger frames —
// the same age span covered at a different rate.
drawRibbon(x: margin, heights: [1.5, 1.0, 1.3, 0.9, 1.2], warm: true)
drawRibbon(x: margin + columnWidth + gap, heights: [1.2, 2.1, 1.4], warm: false)

guard let image = context.makeImage() else { fatalError("could not render image") }

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("could not create \(outputPath)") }

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(outputPath)") }

print("wrote \(outputPath) (\(side)x\(side), opaque)")
