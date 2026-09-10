import SwiftUI

/// L'icône d'un groupe, dessinée à partir du tracé que la box publie.
///
/// Le groupe emporte son tracé plutôt que le nom de son icône : le widget
/// dessine ainsi n'importe quelle icône du jeu de la box sans embarquer ni sa
/// police ni son catalogue, et sans se périmer quand la box en ajoute.
struct IconPath: Shape {
    let commands: String

    /// Les icônes Material Design sont dessinées dans un carré de 24.
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        var reader = SVGPath(commands)
        let drawn = reader.parse()
        let side = min(rect.width, rect.height)
        let scale = side / viewBox
        let transform = CGAffineTransform(
            translationX: rect.midX - side / 2,
            y: rect.midY - side / 2
        )
        .scaledBy(x: scale, y: scale)
        return drawn.applying(transform)
    }
}

/// Lecture d'un attribut `d` de SVG.
///
/// Assez pour le jeu Material Design : segments droits, courbes de Bézier et
/// arcs elliptiques, en coordonnées absolues comme relatives. Un tracé mal
/// formé s'arrête là où il cesse d'être lisible plutôt que d'échouer — une
/// icône tronquée reste préférable à un widget vide.
struct SVGPath {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) { characters = Array(text) }

    private var current = CGPoint.zero
    private var subpathStart = CGPoint.zero

    /// Dernier point de contrôle, que `S` et `T` reflètent pour enchaîner deux
    /// courbes sans cassure.
    private var lastControl: CGPoint?
    private var lastCommand: Character = " "

    mutating func parse() -> Path {
        var path = Path()
        while true {
            skipSeparators()
            guard index < characters.count else { break }

            let character = characters[index]
            var command: Character
            if character.isLetter {
                command = character
                index += 1
            } else if lastCommand != " " {
                // Une commande répétée s'écrit sans se renommer. Après un
                // déplacement, la répétition trace des droites.
                command = lastCommand == "M" ? "L" : (lastCommand == "m" ? "l" : lastCommand)
            } else {
                break
            }

            guard apply(command, to: &path) else { break }
            lastCommand = command
        }
        return path
    }

    private mutating func apply(_ command: Character, to path: inout Path) -> Bool {
        let relative = command.isLowercase
        let base = relative ? current : .zero

        switch Character(command.uppercased()) {
        case "M":
            guard let point = readPoint(base) else { return false }
            path.move(to: point)
            current = point
            subpathStart = point
            lastControl = nil

        case "L":
            guard let point = readPoint(base) else { return false }
            path.addLine(to: point)
            current = point
            lastControl = nil

        case "H":
            guard let x = readNumber() else { return false }
            let point = CGPoint(x: base.x + x, y: current.y)
            path.addLine(to: point)
            current = point
            lastControl = nil

        case "V":
            guard let y = readNumber() else { return false }
            let point = CGPoint(x: current.x, y: base.y + y)
            path.addLine(to: point)
            current = point
            lastControl = nil

        case "C":
            guard let c1 = readPoint(base), let c2 = readPoint(base), let end = readPoint(base)
            else { return false }
            path.addCurve(to: end, control1: c1, control2: c2)
            current = end
            lastControl = c2

        case "S":
            guard let c2 = readPoint(base), let end = readPoint(base) else { return false }
            let c1 = reflected(lastControl)
            path.addCurve(to: end, control1: c1, control2: c2)
            current = end
            lastControl = c2

        case "Q":
            guard let control = readPoint(base), let end = readPoint(base) else { return false }
            path.addQuadCurve(to: end, control: control)
            current = end
            lastControl = control

        case "T":
            guard let end = readPoint(base) else { return false }
            let control = reflected(lastControl)
            path.addQuadCurve(to: end, control: control)
            current = end
            lastControl = control

        case "A":
            guard let rx = readNumber(), let ry = readNumber(), let rotation = readNumber(),
                  let largeArc = readNumber(), let sweep = readNumber(),
                  let end = readPoint(base)
            else { return false }
            addArc(
                to: end, rx: rx, ry: ry, rotation: rotation,
                largeArc: largeArc != 0, sweep: sweep != 0, path: &path
            )
            current = end
            lastControl = nil

        case "Z":
            path.closeSubpath()
            current = subpathStart
            lastControl = nil

        default:
            return false
        }
        return true
    }

    /// Le miroir du dernier point de contrôle par rapport au point courant.
    private func reflected(_ control: CGPoint?) -> CGPoint {
        guard let control else { return current }
        return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
    }

    /// Un arc elliptique, approché par des courbes de Bézier.
    ///
    /// SVG décrit l'arc par son point d'arrivée ; le tracer demande son centre.
    /// La conversion suit l'annexe F.6 de la spécification SVG.
    private mutating func addArc(
        to end: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat,
        largeArc: Bool, sweep: Bool, path: inout Path
    ) {
        let start = current
        if rx == 0 || ry == 0 || (start.x == end.x && start.y == end.y) {
            path.addLine(to: end)
            return
        }

        var radiusX = abs(rx)
        var radiusY = abs(ry)
        let angle = rotation * .pi / 180
        let cosAngle = cos(angle), sinAngle = sin(angle)

        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosAngle * dx + sinAngle * dy
        let y1 = -sinAngle * dx + cosAngle * dy

        // Des rayons trop courts pour relier les deux points sont agrandis
        // jusqu'à ce que l'arc devienne traçable, comme l'impose la spec.
        let excess = (x1 * x1) / (radiusX * radiusX) + (y1 * y1) / (radiusY * radiusY)
        if excess > 1 {
            radiusX *= sqrt(excess)
            radiusY *= sqrt(excess)
        }

        let denominator = radiusX * radiusX * y1 * y1 + radiusY * radiusY * x1 * x1
        let numerator = max(0, radiusX * radiusX * radiusY * radiusY - denominator)
        var factor = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { factor = -factor }

        let cx1 = factor * radiusX * y1 / radiusY
        let cy1 = -factor * radiusY * x1 / radiusX
        let centerX = cosAngle * cx1 - sinAngle * cy1 + (start.x + end.x) / 2
        let centerY = sinAngle * cx1 + cosAngle * cy1 + (start.y + end.y) / 2

        func angleOf(_ x: CGFloat, _ y: CGFloat) -> CGFloat { atan2(y, x) }
        let startAngle = angleOf((x1 - cx1) / radiusX, (y1 - cy1) / radiusY)
        let endAngle = angleOf((-x1 - cx1) / radiusX, (-y1 - cy1) / radiusY)

        var sweepAngle = endAngle - startAngle
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        // Une Bézier cubique ne suit fidèlement qu'un quart de tour : au-delà,
        // l'arc est découpé.
        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let step = sweepAngle / CGFloat(segments)
        let control = 4.0 / 3.0 * tan(step / 4)

        var theta = startAngle
        for _ in 0..<segments {
            let next = theta + step
            let cosStart = cos(theta), sinStart = sin(theta)
            let cosEnd = cos(next), sinEnd = sin(next)

            func point(_ cosValue: CGFloat, _ sinValue: CGFloat) -> CGPoint {
                CGPoint(
                    x: centerX + cosAngle * radiusX * cosValue - sinAngle * radiusY * sinValue,
                    y: centerY + sinAngle * radiusX * cosValue + cosAngle * radiusY * sinValue
                )
            }

            let from = point(cosStart, sinStart)
            let to = point(cosEnd, sinEnd)
            let c1 = CGPoint(
                x: from.x + control * (-cosAngle * radiusX * sinStart - sinAngle * radiusY * cosStart),
                y: from.y + control * (-sinAngle * radiusX * sinStart + cosAngle * radiusY * cosStart)
            )
            let c2 = CGPoint(
                x: to.x - control * (-cosAngle * radiusX * sinEnd - sinAngle * radiusY * cosEnd),
                y: to.y - control * (-sinAngle * radiusX * sinEnd + cosAngle * radiusY * cosEnd)
            )
            path.addCurve(to: to, control1: c1, control2: c2)
            theta = next
        }
    }

    // --- Lecture des nombres -------------------------------------------------

    private mutating func skipSeparators() {
        while index < characters.count,
              characters[index] == " " || characters[index] == ","
                || characters[index] == "\n" || characters[index] == "\t"
                || characters[index] == "\r" {
            index += 1
        }
    }

    private mutating func readPoint(_ base: CGPoint) -> CGPoint? {
        guard let x = readNumber(), let y = readNumber() else { return nil }
        return CGPoint(x: base.x + x, y: base.y + y)
    }

    private mutating func readNumber() -> CGFloat? {
        skipSeparators()
        var text = ""
        if index < characters.count, characters[index] == "-" || characters[index] == "+" {
            text.append(characters[index])
            index += 1
        }
        while index < characters.count {
            let character = characters[index]
            if character.isNumber || character == "." {
                text.append(character)
                index += 1
            } else if character == "e" || character == "E" {
                text.append(character)
                index += 1
                if index < characters.count,
                   characters[index] == "-" || characters[index] == "+" {
                    text.append(characters[index])
                    index += 1
                }
            } else {
                break
            }
        }
        return Double(text).map { CGFloat($0) }
    }
}
