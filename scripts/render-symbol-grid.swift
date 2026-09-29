import AppKit
import Foundation

let symbols: [String] = [
    "play.circle.fill",
    "play.fill",
    "play.circle",
    "play.square.fill",
    "arrow.clockwise.circle.fill",
    "arrow.clockwise.circle",
    "clock.badge.checkmark.fill",
    "clock.badge.checkmark",
    "clock.arrow.circlepath",
    "checkmark.circle.fill",
    "checkmark.circle",
    "checkmark.seal.fill",
    "bolt.circle.fill",
    "bolt.badge.clock.fill",
    "bolt.horizontal.circle.fill",
    "hourglass.circle.fill",
    "hourglass.badge.plus",
    "timer.circle.fill",
    "alarm.fill",
    "bell.badge.fill",
    "bell.circle.fill",
    "calendar.badge.clock",
    "calendar.circle.fill",
    "sunrise.fill",
    "sun.max.fill",
    "moon.stars.fill",
    "figure.walk.circle.fill",
    "figure.run.circle.fill",
    "arrow.right.circle.fill",
    "arrow.forward.circle.fill",
    "return",
    "return.left",
    "gobackward",
    "goforward",
    "repeat.circle.fill",
    "infinity.circle.fill",
    "sparkles",
    "wand.and.stars",
    "flag.checkered.circle.fill",
    "location.fill.viewfinder",
    "scope",
    "target",
    "hand.thumbsup.fill",
    "face.smiling.inverse",
    "power.circle.fill",
    "powerplug.fill",
    "flashlight.on.fill",
    "light.beacon.max.fill",
    "app.badge.checkmark",
    "desktopcomputer.and.arrow.down",
]

let outputPath = CommandLine.arguments.dropFirst().first ?? "/tmp/claudebar-symbol-grid.png"
let columns = 5
let cellWidth: CGFloat = 250
let cellHeight: CGFloat = 120
let padding: CGFloat = 24
let headerHeight: CGFloat = 72
let rows = Int(ceil(Double(symbols.count) / Double(columns)))
let canvasSize = NSSize(
    width: CGFloat(columns) * cellWidth + padding * 2,
    height: CGFloat(rows) * cellHeight + padding * 2 + headerHeight
)

let image = NSImage(size: canvasSize)
image.lockFocus()

NSColor.windowBackgroundColor.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
paragraph.lineBreakMode = .byTruncatingMiddle

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: NSColor.labelColor,
]

let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor.secondaryLabelColor,
]

let indexAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
    .foregroundColor: NSColor.tertiaryLabelColor,
]

let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph,
]

("ClaudeBar icon options").draw(
    at: NSPoint(x: padding, y: canvasSize.height - 42),
    withAttributes: titleAttrs
)
("50 SF Symbols with numbers").draw(
    at: NSPoint(x: padding, y: canvasSize.height - 64),
    withAttributes: subtitleAttrs
)

for (idx, symbolName) in symbols.enumerated() {
    let row = idx / columns
    let column = idx % columns
    let originX = padding + CGFloat(column) * cellWidth
    let originY = canvasSize.height - headerHeight - padding - (CGFloat(row + 1) * cellHeight)
    let cardRect = NSRect(x: originX, y: originY, width: cellWidth - 12, height: cellHeight - 12)

    NSColor.controlBackgroundColor.setFill()
    let card = NSBezierPath(roundedRect: cardRect, xRadius: 18, yRadius: 18)
    card.fill()

    NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
    card.lineWidth = 1
    card.stroke()

    let numberString = "\(idx + 1)."
    numberString.draw(
        at: NSPoint(x: cardRect.minX + 14, y: cardRect.maxY - 26),
        withAttributes: indexAttrs
    )

    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName) {
        let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        let configured = symbol.withSymbolConfiguration(config) ?? symbol
        let iconRect = NSRect(
            x: cardRect.midX - 20,
            y: cardRect.midY - 6,
            width: 40,
            height: 40
        )
        configured.draw(in: iconRect)
    }

    let textRect = NSRect(
        x: cardRect.minX + 12,
        y: cardRect.minY + 12,
        width: cardRect.width - 24,
        height: 34
    )
    symbolName.draw(in: textRect, withAttributes: labelAttrs)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to render PNG\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print(outputPath)
