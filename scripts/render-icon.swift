#!/usr/bin/env swift
// Generates a 1024x1024 app icon PNG.
//
// Design intent: dev-tool / terminal aesthetic, deliberately *not* the
// purple-gradient look that's become the AI/SaaS default. Reads as a git tool:
//
//   - Solid dark charcoal background with a faint inner border
//   - A real-looking commit graph in git's brand orange (#F05033) —
//     two branches merging into a trunk with a follow-up commit
//   - Pure white commit nodes with tiny inner highlights for crispness
//
// The graph mirrors the menu-bar glyph but with more nodes so it tells the
// story of "PRs that get rebased and merged" at a glance.

import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    fputs("usage: render-icon.swift <output.png>\n", stderr)
    exit(1)
}
let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// MARK: - Background

let cornerRadius = size * 0.224
let canvasRect = NSRect(x: 0, y: 0, width: size, height: size)
let bgPath = NSBezierPath(roundedRect: canvasRect, xRadius: cornerRadius, yRadius: cornerRadius)

NSGraphicsContext.current?.saveGraphicsState()
bgPath.addClip()

// Solid charcoal — terminal vibe. Slightly warmer than pure black to feel
// less stark next to other Mac icons.
NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0).setFill()
canvasRect.fill()

// Faint top-left vignette for depth without looking like a gradient icon.
let vignette = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.04),
    NSColor.clear,
])!
vignette.draw(
    fromCenter: NSPoint(x: size * 0.28, y: size * 0.85), radius: 0,
    toCenter: NSPoint(x: size * 0.28, y: size * 0.85), radius: size * 0.65,
    options: .drawsBeforeStartingLocation
)

// Inner border — single hairline a few px in. Reads as a precise UI element,
// not a soft AI-blob.
let borderInset: CGFloat = size * 0.01
let borderRect = canvasRect.insetBy(dx: borderInset, dy: borderInset)
let borderRadius = max(0, cornerRadius - borderInset)
let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: borderRadius, yRadius: borderRadius)
borderPath.lineWidth = size * 0.005
NSColor(srgbRed: 0.20, green: 0.22, blue: 0.25, alpha: 1.0).setStroke()
borderPath.stroke()

// MARK: - Commit graph
//
// Geometry: two top branches merging at a node, then a trunk continuing to
// a final commit. Nodes:
//
//        ●(A)         ●(B)
//        |            |
//        └────●(M)────┘
//             |
//             ●(C)
//
// All coordinates in fractions of `size` so the design scales identically.

let leftX     = size * 0.30
let rightX    = size * 0.70
let centerX   = size * 0.50

let topY      = size * 0.78
let mergeY    = size * 0.50
let bottomY   = size * 0.22

let nodeA = NSPoint(x: leftX,   y: topY)
let nodeB = NSPoint(x: rightX,  y: topY)
let nodeM = NSPoint(x: centerX, y: mergeY)
let nodeC = NSPoint(x: centerX, y: bottomY)

let strokeWidth: CGFloat = size * 0.085
let nodeRadius: CGFloat  = size * 0.062

// Git's brand orange. Slightly desaturated so it doesn't burn at small sizes.
let gitOrange = NSColor(srgbRed: 0.94, green: 0.31, blue: 0.20, alpha: 1.0)
gitOrange.setStroke()
gitOrange.setFill()

// Soft drop shadow under the strokes — gives the graph a tiny lift from the
// flat background without looking glowy.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
shadow.shadowBlurRadius = size * 0.025
shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
shadow.set()

// Left branch — vertical drop, then a smooth curve into the merge.
let curveOffset: CGFloat = size * 0.06
let leftBranch = NSBezierPath()
leftBranch.move(to: nodeA)
leftBranch.line(to: NSPoint(x: leftX, y: mergeY + curveOffset))
leftBranch.curve(
    to: nodeM,
    controlPoint1: NSPoint(x: leftX, y: mergeY),
    controlPoint2: NSPoint(x: nodeM.x - size * 0.10, y: mergeY)
)
leftBranch.lineWidth = strokeWidth
leftBranch.lineCapStyle = .round
leftBranch.lineJoinStyle = .round
leftBranch.stroke()

// Right branch — mirror.
let rightBranch = NSBezierPath()
rightBranch.move(to: nodeB)
rightBranch.line(to: NSPoint(x: rightX, y: mergeY + curveOffset))
rightBranch.curve(
    to: nodeM,
    controlPoint1: NSPoint(x: rightX, y: mergeY),
    controlPoint2: NSPoint(x: nodeM.x + size * 0.10, y: mergeY)
)
rightBranch.lineWidth = strokeWidth
rightBranch.lineCapStyle = .round
rightBranch.lineJoinStyle = .round
rightBranch.stroke()

// Trunk — straight line from merge to final commit.
let trunk = NSBezierPath()
trunk.move(to: nodeM)
trunk.line(to: nodeC)
trunk.lineWidth = strokeWidth
trunk.lineCapStyle = .round
trunk.stroke()

// Disable shadow for the filled nodes — we want them to read as crisp
// solid disks, not glow.
NSGraphicsContext.current?.saveGraphicsState()
let nullShadow = NSShadow()
nullShadow.shadowColor = .clear
nullShadow.set()

// Filled white commit nodes with a thin orange ring so they read as commits
// even at the smallest icon sizes.
let ringWidth: CGFloat = size * 0.018
for point in [nodeA, nodeB, nodeM, nodeC] {
    // Inner white disk
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: point.x - nodeRadius,
        y: point.y - nodeRadius,
        width: nodeRadius * 2,
        height: nodeRadius * 2
    )).fill()
    // Outer orange ring
    gitOrange.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(
        x: point.x - nodeRadius,
        y: point.y - nodeRadius,
        width: nodeRadius * 2,
        height: nodeRadius * 2
    ))
    ring.lineWidth = ringWidth
    ring.stroke()
}

NSGraphicsContext.current?.restoreGraphicsState()
NSGraphicsContext.current?.restoreGraphicsState()
image.unlockFocus()

// MARK: - Save

guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let pngData = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(pngData.count) bytes)")
