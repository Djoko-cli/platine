// Dessine le calque de l'icône de Platine : un disque vu de dessus (le contour, un sillon et l'étiquette pleine) et le
// bras de lecture posé dessus, en corail sur fond transparent (le fond crème est posé par l'aperçu ou par l'icône).
// Une couleur, aucun effet, comme les autres apps de Djoko.
// Usage : swift outils/dessiner-icone.swift <calque.png> [aperçu.png]
// Le calque de l'app : Platine/AppIcon.icon/Assets/platine.png
import AppKit
import CoreGraphics

guard (2...3).contains(CommandLine.arguments.count) else {
    print("usage : swift outils/dessiner-icone.swift <calque.png> [aperçu.png]")
    exit(2)
}
let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let corail = CGColor(colorSpace: space, components: [0xE0 / 255.0, 0x5A / 255.0, 0x3C / 255.0, 1])!
let creme = CGColor(colorSpace: space, components: [0.95686, 0.92941, 0.88235, 1])!

func dessiner(fond: Bool) -> CGImage {
    let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    if fond {
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerWidth: 230,
                               cornerHeight: 230, transform: nil))
        context.setFillColor(creme)
        context.fillPath()
    }
    context.setStrokeColor(corail)
    context.setFillColor(corail)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    // Le disque, un peu décalé vers le bas à gauche pour laisser la place au bras.
    let centre = CGPoint(x: 470, y: 560)
    context.setLineWidth(60)
    context.strokeEllipse(in: CGRect(x: centre.x - 300, y: centre.y - 300, width: 600, height: 600))
    // Un sillon, plus fin.
    context.setLineWidth(28)
    context.strokeEllipse(in: CGRect(x: centre.x - 190, y: centre.y - 190, width: 380, height: 380))
    // L'étiquette pleine.
    let rayon: CGFloat = 62
    context.fillEllipse(in: CGRect(x: centre.x - rayon, y: centre.y - rayon, width: 2 * rayon, height: 2 * rayon))
    // Le bras : le pivot en haut à droite, puis le bras qui descend se poser sur le sillon.
    // Il est détaché du disque par un liseré vide, pour se lire posé dessus.
    let bras = CGMutablePath()
    bras.move(to: CGPoint(x: 840, y: 190))
    bras.addLine(to: CGPoint(x: 840, y: 560))
    bras.addLine(to: CGPoint(x: 615, y: 682))
    context.saveGState()
    context.setBlendMode(fond ? .normal : .clear)
    context.setStrokeColor(creme)
    context.setLineWidth(120)
    context.addPath(bras)
    context.strokePath()
    context.restoreGState()
    context.setLineWidth(60)
    context.addPath(bras)
    context.strokePath()
    let pivot: CGFloat = 54
    context.fillEllipse(in: CGRect(x: 840 - pivot, y: 190 - pivot, width: 2 * pivot, height: 2 * pivot))
    return context.makeImage()!
}

for (index, fond) in [(1, false), (2, true)] where index < CommandLine.arguments.count {
    let sortie = URL(fileURLWithPath: CommandLine.arguments[index])
    try NSBitmapImageRep(cgImage: dessiner(fond: fond)).representation(using: .png, properties: [:])!.write(to: sortie)
    print("écrit : \(sortie.lastPathComponent)")
}
