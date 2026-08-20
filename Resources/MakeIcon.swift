// Draws Resources/icon-1024.png. Run once with:
//   swift Resources/MakeIcon.swift
// The PNG is committed so the build never depends on running code.
//
// The glyph is the app's own signature visualization: an orange prefill spike
// resolving into a steady blue decode plateau over an aqua baseline.
import AppKit

let side = 1024.0
let img = NSImage(size: NSSize(width: side, height: side))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func c(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(red: Double((hex >> 16) & 0xFF)/255, green: Double((hex >> 8) & 0xFF)/255,
            blue: Double(hex & 0xFF)/255, alpha: a)
}

// macOS squircle plate
let inset = side * 0.055
let plate = CGRect(x: inset, y: inset, width: side - inset*2, height: side - inset*2)
let r = plate.width * 0.2237
ctx.setFillColor(c(0x0B0D0F))
ctx.addPath(CGPath(roundedRect: plate, cornerWidth: r, cornerHeight: r, transform: nil))
ctx.fillPath()
ctx.setStrokeColor(c(0x22262B)); ctx.setLineWidth(side * 0.006)
ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: side*0.03, dy: side*0.03),
                   cornerWidth: r*0.85, cornerHeight: r*0.85, transform: nil))
ctx.strokePath()

let x0 = plate.minX + plate.width*0.14, x1 = plate.maxX - plate.width*0.14
let w = x1 - x0
func trace(_ pts: [(Double, Double)], _ color: CGColor, _ lw: Double) {
    ctx.setStrokeColor(color); ctx.setLineWidth(lw)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (i, p) in pts.enumerated() {
        let pt = CGPoint(x: x0 + w*p.0, y: plate.minY + plate.height*p.1)
        i == 0 ? ctx.move(to: pt) : ctx.addLine(to: pt)
    }
    ctx.strokePath()
}
// baseline, prefill spike, decode plateau
trace([(0,0.28),(1,0.28)], c(0x199E70), side*0.018)
trace([(0.0,0.34),(0.16,0.34),(0.22,0.80),(0.30,0.80),(0.36,0.50)], c(0xD95926), side*0.045)
trace([(0.36,0.50),(0.46,0.56),(0.54,0.50),(0.62,0.57),(0.70,0.51),(0.78,0.56),(0.88,0.52),(1.0,0.54)],
      c(0x3987E5), side*0.045)
img.unlockFocus()

let tiff = img.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: "Resources/icon-1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
