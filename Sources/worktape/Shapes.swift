import CoreGraphics

func drawShape(_ scalar: UInt32, in box: CGRect, lineWidth: CGFloat, color: CGColor, context: CGContext) -> Bool {
    let draw: () -> Void
    switch scalar {
    case 0x2504...0x250B, 0x254C...0x254F:
        draw = { drawDashes(scalar, in: box, lineWidth: lineWidth, context: context) }
    case 0x2500...0x254B, 0x2574...0x257F:
        draw = { drawLines(scalar, in: box, lineWidth: lineWidth, context: context) }
    case 0x256D...0x2570:
        draw = { drawArc(scalar, in: box, context: context) }
    case 0x2571...0x2573:
        draw = { drawDiagonals(scalar, in: box, context: context) }
    case 0x2580...0x259F:
        draw = { drawBlock(scalar, in: box, color: color, context: context) }
    case 0xE0B0...0xE0BF:
        draw = { drawPowerline(scalar, in: box, lineWidth: lineWidth, context: context) }
    default:
        return false
    }
    context.saveGState()
    defer { context.restoreGState() }
    context.setFillColor(color)
    context.setStrokeColor(color)
    context.setLineWidth(lineWidth)
    draw()
    return true
}

private struct Arms {
    let up: Int
    let right: Int
    let down: Int
    let left: Int

    init(upRightDownLeft weights: Substring) {
        let digits = weights.compactMap(\.wholeNumberValue)
        (up, right, down, left) = (digits[0], digits[1], digits[2], digits[3])
    }

    var widest: Int { max(up, right, down, left) }
}

private let boxArms: [UInt32: Arms] = {
    let lines = """
    0101 0202 1010 2020 0101 0202 1010 2020 0101 0202 1010 2020 0110 0210 0120 0220
    0011 0012 0021 0022 1100 1200 2100 2200 1001 1002 2001 2002 1110 1210 2110 1120
    2120 2210 1220 2220 1011 1012 2011 1021 2021 2012 1022 2022 0111 0112 0211 0212
    0121 0122 0221 0222 1101 1102 1201 1202 2101 2102 2201 2202 1111 1112 1211 1212
    2111 1121 2121 2112 2211 1122 1221 2212 1222 2122 2221 2222 0101 0202 1010 2020
    """.split(whereSeparator: \.isWhitespace)
    let halves = "0001 1000 0100 0010 0002 2000 0200 0020 0201 1020 0102 2010".split(separator: " ")
    var arms: [UInt32: Arms] = [:]
    for (offset, weights) in lines.enumerated() { arms[0x2500 + UInt32(offset)] = Arms(upRightDownLeft: weights) }
    for (offset, weights) in halves.enumerated() { arms[0x2574 + UInt32(offset)] = Arms(upRightDownLeft: weights) }
    return arms
}()

private func centered(_ position: CGFloat, lineWidth: CGFloat) -> CGFloat {
    (position - lineWidth / 2).rounded() + lineWidth / 2
}

private func drawLines(_ scalar: UInt32, in box: CGRect, lineWidth: CGFloat, context: CGContext) {
    guard let arms = boxArms[scalar] else { return }
    func thickness(_ weight: Int) -> CGFloat { CGFloat(weight) * lineWidth }
    let widest = thickness(arms.widest)
    let midX = centered(box.midX, lineWidth: lineWidth)
    let midY = centered(box.midY, lineWidth: lineWidth)

    let (up, right, down, left) = (thickness(arms.up), thickness(arms.right), thickness(arms.down), thickness(arms.left))
    if up > 0 {
        context.fill(CGRect(x: midX - up / 2, y: midY - widest / 2, width: up, height: box.maxY - midY + widest / 2))
    }
    if down > 0 {
        context.fill(CGRect(x: midX - down / 2, y: box.minY, width: down, height: midY - box.minY + widest / 2))
    }
    if right > 0 {
        context.fill(CGRect(x: midX - widest / 2, y: midY - right / 2, width: box.maxX - midX + widest / 2, height: right))
    }
    if left > 0 {
        context.fill(CGRect(x: box.minX, y: midY - left / 2, width: midX - box.minX + widest / 2, height: left))
    }
}

private func drawDashes(_ scalar: UInt32, in box: CGRect, lineWidth: CGFloat, context: CGContext) {
    guard let arms = boxArms[scalar] else { return }
    let count: Int = switch scalar {
    case 0x2504...0x2507: 3
    case 0x2508...0x250B: 4
    default: 2
    }
    let horizontal = arms.right > 0
    let thickness = CGFloat(arms.widest) * lineWidth
    let segment = (horizontal ? box.width : box.height) / CGFloat(count)
    for index in 0..<count {
        let start = CGFloat(index) * segment + segment / 6
        context.fill(horizontal
            ? CGRect(x: box.minX + start, y: centered(box.midY, lineWidth: lineWidth) - thickness / 2, width: segment * 2 / 3, height: thickness)
            : CGRect(x: centered(box.midX, lineWidth: lineWidth) - thickness / 2, y: box.minY + start, width: thickness, height: segment * 2 / 3))
    }
}

private func drawDiagonals(_ scalar: UInt32, in box: CGRect, context: CGContext) {
    if scalar != 0x2572 {
        context.strokeLineSegments(between: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)])
    }
    if scalar != 0x2571 {
        context.strokeLineSegments(between: [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.minY)])
    }
}

private func drawArc(_ scalar: UInt32, in box: CGRect, context: CGContext) {
    let center = CGPoint(x: box.midX, y: box.midY)
    let radius = min(box.width, box.height) / 2
    let vertical = scalar == 0x256D || scalar == 0x256E ? box.minY : box.maxY
    let horizontal = scalar == 0x256D || scalar == 0x2570 ? box.maxX : box.minX
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: vertical))
    path.addArc(tangent1End: center, tangent2End: CGPoint(x: horizontal, y: center.y), radius: radius)
    path.addLine(to: CGPoint(x: horizontal, y: center.y))
    context.addPath(path)
    context.strokePath()
}

private func drawBlock(_ scalar: UInt32, in box: CGRect, color: CGColor, context: CGContext) {
    func rows(_ from: CGFloat, _ to: CGFloat) -> CGRect {
        let bottom = (box.minY + box.height * from).rounded()
        return CGRect(x: box.minX, y: bottom, width: box.width, height: (box.minY + box.height * to).rounded() - bottom)
    }
    func columns(_ from: CGFloat, _ to: CGFloat) -> CGRect {
        let left = (box.minX + box.width * from).rounded()
        return CGRect(x: left, y: box.minY, width: (box.minX + box.width * to).rounded() - left, height: box.height)
    }

    switch scalar {
    case 0x2580:
        context.fill(rows(0.5, 1))
    case 0x2581...0x2588:
        context.fill(rows(0, CGFloat(scalar - 0x2580) / 8))
    case 0x2589...0x258F:
        context.fill(columns(0, CGFloat(0x2590 - scalar) / 8))
    case 0x2590:
        context.fill(columns(0.5, 1))
    case 0x2591...0x2593:
        context.setFillColor(color.copy(alpha: CGFloat(scalar - 0x2590) / 4) ?? color)
        context.fill(box)
    case 0x2594:
        context.fill(rows(7.0 / 8, 1))
    case 0x2595:
        context.fill(columns(7.0 / 8, 1))
    default:
        let upper = rows(0.5, 1), lower = rows(0, 0.5)
        let left = columns(0, 0.5), right = columns(0.5, 1)
        let upperLeft = upper.intersection(left), upperRight = upper.intersection(right)
        let lowerLeft = lower.intersection(left), lowerRight = lower.intersection(right)
        let quadrants = [
            [lowerLeft], [lowerRight], [upperLeft], [upperLeft, lowerLeft, lowerRight], [upperLeft, lowerRight],
            [upperLeft, upperRight, lowerLeft], [upperLeft, upperRight, lowerRight], [upperRight],
            [upperRight, lowerLeft], [upperRight, lowerLeft, lowerRight],
        ]
        quadrants[Int(scalar - 0x2596)].forEach(context.fill)
    }
}

private func drawPowerline(_ scalar: UInt32, in box: CGRect, lineWidth: CGFloat, context: CGContext) {
    let (minX, maxX, minY, maxY, midY) = (box.minX, box.maxX, box.minY, box.maxY, box.midY)
    func fill(_ points: [CGPoint]) {
        context.addLines(between: points)
        context.closePath()
        context.fillPath()
    }
    func stroke(_ points: [CGPoint]) {
        context.addLines(between: points)
        context.strokePath()
    }
    func cap(right: Bool, filled: Bool) {
        let center = CGPoint(x: right ? minX : maxX, y: midY)
        let oval = CGRect(x: center.x - box.width, y: minY, width: box.width * 2, height: box.height)
        context.clip(to: box)
        context.addEllipse(in: filled ? oval : oval.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        filled ? context.fillPath() : context.strokePath()
    }

    switch scalar {
    case 0xE0B0: fill([CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: midY), CGPoint(x: minX, y: maxY)])
    case 0xE0B1: stroke([CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: midY), CGPoint(x: minX, y: maxY)])
    case 0xE0B2: fill([CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: midY), CGPoint(x: maxX, y: maxY)])
    case 0xE0B3: stroke([CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: midY), CGPoint(x: maxX, y: maxY)])
    case 0xE0B4: cap(right: true, filled: true)
    case 0xE0B5: cap(right: true, filled: false)
    case 0xE0B6: cap(right: false, filled: true)
    case 0xE0B7: cap(right: false, filled: false)
    case 0xE0B8: fill([CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: maxY)])
    case 0xE0BA: fill([CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY)])
    case 0xE0BC: fill([CGPoint(x: minX, y: minY), CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)])
    case 0xE0BE: fill([CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY), CGPoint(x: maxX, y: minY)])
    case 0xE0B9, 0xE0BF: stroke([CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: minY)])
    default: stroke([CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)])
    }
}
