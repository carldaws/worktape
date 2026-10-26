import CoreGraphics
import CoreText
import Foundation
import MachO
import SwiftTerm

struct VideoLayout: Equatable {
    static let widest = 3840
    static let tallest = 2160
    static let largestFontSize = 32
    static let lineHeight = 1.4

    let columns: Int
    let rows: Int
    let fontSize: Int
    let cellWidth: Int
    let cellHeight: Int

    init(columns: Int, rows: Int, advance: Double) {
        self.columns = columns
        self.rows = rows
        var size = Self.largestFontSize
        while size > 1 {
            let width = Self.cellWidth(size: size, advance: advance)
            let height = Self.cellHeight(size: size)
            if (columns + 1) * width <= Self.widest && (rows + 1) * height <= Self.tallest {
                break
            }
            size -= 1
        }
        fontSize = size
        cellWidth = Self.cellWidth(size: size, advance: advance)
        cellHeight = Self.cellHeight(size: size)
    }

    var left: Int { cellWidth / 2 }
    var top: Int { cellHeight / 2 }
    var width: Int { roundedUpToEven(columns * cellWidth + left * 2) }
    var height: Int { roundedUpToEven(rows * cellHeight + top * 2) }

    private func roundedUpToEven(_ length: Int) -> Int {
        (length + 1) / 2 * 2
    }

    private static func cellWidth(size: Int, advance: Double) -> Int {
        max(1, Int((Double(size) * advance).rounded()))
    }

    private static func cellHeight(size: Int) -> Int {
        max(1, Int((Double(size) * lineHeight).rounded()))
    }
}

struct TerminalFonts {
    static let families = ["JetBrains Mono", "Fira Code", "SF Mono", "Menlo", "Consolas", "DejaVu Sans Mono", "Liberation Mono"]

    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let symbols: CTFont?

    init(family: CTFontDescriptor, size: CGFloat) {
        regular = CTFontCreateWithFontDescriptor(family, size, nil)
        bold = Self.styled(regular, .traitBold)
        italic = Self.styled(regular, .traitItalic)
        boldItalic = Self.styled(regular, [.traitBold, .traitItalic])
        symbols = Self.embeddedSymbols().map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }

    static func installedFamily() -> CTFontDescriptor {
        families.lazy.compactMap(installed).first
            ?? CTFontDescriptorCreateWithNameAndSize("Menlo-Regular" as CFString, 0)
    }

    static func advance(of family: CTFontDescriptor) -> Double {
        let size = 100.0
        let font = CTFontCreateWithFontDescriptor(family, size, nil)
        var character = UniChar(UInt8(ascii: "M"))
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        return CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1) / size
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }

    private static func installed(_ family: String) -> CTFontDescriptor? {
        let wanted = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: 0, kCTFontWeightTrait: 0],
        ] as CFDictionary)
        guard let found = CTFontDescriptorCreateMatchingFontDescriptor(wanted, nil),
              CTFontDescriptorCopyAttribute(found, kCTFontFamilyNameAttribute) as? String == family
        else { return nil }
        return found
    }

    private static func styled(_ font: CTFont, _ traits: CTFontSymbolicTraits) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) ?? font
    }

    private static func embeddedSymbols() -> CTFontDescriptor? {
        var size: UInt = 0
        let image = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(image, "__TEXT", "__symbols_font", &size) else { return nil }
        let data = Data(bytesNoCopy: bytes, count: Int(size), deallocator: .none)
        return CTFontManagerCreateFontDescriptorFromData(data as CFData)
    }
}

final class ScreenPainter {
    let layout: VideoLayout
    private let fonts: TerminalFonts
    private let baseline: CGFloat
    private let lineWidth: CGFloat
    private let underlineOffset: CGFloat
    private let strikeOffset: CGFloat
    private var glyphs: [GlyphKey: Glyph] = [:]
    private var colors: [UInt32: CGColor] = [:]

    init(columns: Int, rows: Int) {
        let family = TerminalFonts.installedFamily()
        layout = VideoLayout(columns: columns, rows: rows, advance: TerminalFonts.advance(of: family))
        fonts = TerminalFonts(family: family, size: CGFloat(layout.fontSize))
        let ascent = CTFontGetAscent(fonts.regular)
        let descent = CTFontGetDescent(fonts.regular)
        baseline = ((CGFloat(layout.cellHeight) - ascent - descent) / 2 + descent).rounded()
        lineWidth = max(1, CTFontGetUnderlineThickness(fonts.regular).rounded())
        underlineOffset = (CTFontGetUnderlinePosition(fonts.regular) - lineWidth / 2).rounded()
        strikeOffset = (CTFontGetXHeight(fonts.regular) / 2 - lineWidth / 2).rounded()
    }

    func paint(_ screen: TerminalRenderSnapshot, into context: CGContext) {
        let palette = Palette(screen)
        context.setFillColor(color(palette.background))
        context.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))

        let cells = place(screen, palette: palette)
        for cell in cells where cell.background != palette.background {
            context.setFillColor(color(cell.background))
            context.fill(cell.box)
        }
        for cell in cells {
            paintForeground(of: cell, palette: palette, context: context)
        }
    }

    private func place(_ screen: TerminalRenderSnapshot, palette: Palette) -> [PlacedCell] {
        let cursor = screen.cursor.hidden ? nil : screen.cursor
        var placed: [PlacedCell] = []
        for line in screen.lines where line.y < layout.rows {
            let bottom = CGFloat(layout.height - layout.top - (line.y + 1) * layout.cellHeight)
            for (column, cell) in line.cells.enumerated() where column < layout.columns && cell.widthState != .spacerTail {
                let span = cell.widthState == .wide ? 2 : 1
                let box = CGRect(
                    x: CGFloat(layout.left + column * layout.cellWidth), y: bottom,
                    width: CGFloat(span * layout.cellWidth), height: CGFloat(layout.cellHeight)
                )
                let underCursor = cursor.map { $0.y == line.y && min($0.x, screen.cols - 1) == column } ?? false
                placed.append(PlacedCell(cell, in: box, palette: palette, cursor: underCursor ? cursor?.style : nil))
            }
        }
        return placed
    }

    private func paintForeground(of placed: PlacedCell, palette: Palette, context: CGContext) {
        let attribute = placed.cell.attribute
        let box = placed.box
        let text = placed.cell.text
        if !text.isEmpty && text != " " && !attribute.style.contains(.invisible) {
            draw(text, bold: attribute.style.contains(.bold), italic: attribute.style.contains(.italic),
                 in: box, color: color(placed.foreground), context: context)
        }
        if attribute.style.contains(.underline) {
            let underline = attribute.underlineColor.map { palette.resolve($0, foreground: true) } ?? placed.foreground
            drawUnderline(attribute.underlineStyle, in: box, color: color(underline), context: context)
        }
        if attribute.style.contains(.crossedOut) {
            context.setFillColor(color(placed.foreground))
            context.fill(CGRect(x: box.minX, y: box.minY + baseline + strikeOffset, width: box.width, height: lineWidth))
        }
        switch placed.cursor {
        case .blinkBar, .steadyBar:
            context.setFillColor(color(placed.foreground))
            context.fill(CGRect(x: box.minX, y: box.minY, width: max(1, lineWidth * 2), height: box.height))
        case .blinkUnderline, .steadyUnderline:
            context.setFillColor(color(placed.foreground))
            context.fill(CGRect(x: box.minX, y: box.minY, width: box.width, height: max(1, lineWidth * 2)))
        default:
            break
        }
    }

    private func draw(_ text: String, bold: Bool, italic: Bool, in box: CGRect, color: CGColor, context: CGContext) {
        let scalars = text.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first,
           drawShape(scalar.value, in: box, lineWidth: lineWidth, color: color, context: context) {
            return
        }
        let key = GlyphKey(text: text, bold: bold, italic: italic)
        let glyph = glyphs[key] ?? makeGlyph(for: key)
        glyphs[key] = glyph

        let offset = glyph.advance <= box.width ? ((box.width - glyph.advance) / 2).rounded() : 0
        let origin = CGPoint(x: box.minX + offset, y: box.minY + baseline)
        context.setFillColor(color)
        switch glyph.shape {
        case .glyph(let font, var id):
            var position = origin
            CTFontDrawGlyphs(font, &id, &position, 1, context)
        case .line(let line):
            context.textPosition = origin
            CTLineDraw(line, context)
            context.textPosition = .zero
        }
    }

    private func makeGlyph(for key: GlyphKey) -> Glyph {
        let font = fonts.font(bold: key.bold, italic: key.italic)
        let characters = Array(key.text.utf16)
        if key.text.unicodeScalars.count == 1 {
            let fallback = CTFontCreateForString(font, key.text as CFString, CFRange(location: 0, length: characters.count))
            for candidate in [font, fonts.symbols, fallback].compactMap({ $0 }) {
                var ids = [CGGlyph](repeating: 0, count: characters.count)
                if CTFontGetGlyphsForCharacters(candidate, characters, &ids, characters.count) {
                    var id = ids[0]
                    let advance = CTFontGetAdvancesForGlyphs(candidate, .horizontal, &id, nil, 1)
                    return Glyph(shape: .glyph(candidate, id), advance: advance)
                }
            }
        }
        let attributed = NSAttributedString(string: key.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        return Glyph(shape: .line(line), advance: CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func drawUnderline(_ style: UnderlineStyle, in box: CGRect, color: CGColor, context: CGContext) {
        let y = box.minY + baseline + underlineOffset
        context.setFillColor(color)
        switch style {
        case .double:
            context.fill(CGRect(x: box.minX, y: y, width: box.width, height: lineWidth))
            context.fill(CGRect(x: box.minX, y: y - lineWidth * 2, width: box.width, height: lineWidth))
        case .curly:
            let amplitude = max(lineWidth, (CGFloat(layout.cellHeight) / 16).rounded())
            let path = CGMutablePath()
            path.move(to: CGPoint(x: box.minX, y: y))
            path.addCurve(
                to: CGPoint(x: box.maxX, y: y),
                control1: CGPoint(x: box.midX, y: y + amplitude * 2),
                control2: CGPoint(x: box.midX, y: y - amplitude * 2)
            )
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.addPath(path)
            context.strokePath()
        case .dotted, .dashed:
            let pieces = max(1, style == .dotted ? Int(box.width / (lineWidth * 2)) : 2)
            let length = box.width / CGFloat(pieces * 2)
            for piece in 0..<pieces {
                context.fill(CGRect(x: box.minX + CGFloat(piece * 2) * length + length / 2, y: y, width: length, height: lineWidth))
            }
        case .single, .none:
            context.fill(CGRect(x: box.minX, y: y, width: box.width, height: lineWidth))
        }
    }

    private func color(_ rgb: RGB) -> CGColor {
        if let cached = colors[rgb.packed] {
            return cached
        }
        let made = CGColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
        colors[rgb.packed] = made
        return made
    }
}

struct RGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var packed: UInt32 { UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue) }

    func mixed(with other: RGB) -> RGB {
        RGB(
            red: UInt8((UInt16(red) + UInt16(other.red)) / 2),
            green: UInt8((UInt16(green) + UInt16(other.green)) / 2),
            blue: UInt8((UInt16(blue) + UInt16(other.blue)) / 2)
        )
    }
}

extension RGB {
    init(_ color: SwiftTerm.Color) {
        self.init(red: UInt8(color.red >> 8), green: UInt8(color.green >> 8), blue: UInt8(color.blue >> 8))
    }

    init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xff), green: UInt8(value >> 8 & 0xff), blue: UInt8(value & 0xff))
    }
}

private struct Palette {
    let foreground: RGB
    let background: RGB
    let colors: [RGB]

    init(_ screen: TerminalRenderSnapshot) {
        let foreground = RGB(screen.foregroundColor)
        let background = RGB(screen.backgroundColor)
        self.foreground = screen.reverseVideo ? background : foreground
        self.background = screen.reverseVideo ? foreground : background
        colors = screen.palette.map(RGB.init)
    }

    func resolve(_ color: Attribute.Color, foreground isForeground: Bool) -> RGB {
        switch color {
        case .ansi256(let code):
            colors.indices.contains(Int(code)) ? colors[Int(code)] : foreground
        case .trueColor(let red, let green, let blue):
            RGB(red: red, green: green, blue: blue)
        case .defaultColor:
            isForeground ? foreground : background
        case .defaultInvertedColor:
            isForeground ? background : foreground
        }
    }
}

private struct PlacedCell {
    let cell: RenderSnapshotCell
    let box: CGRect
    let foreground: RGB
    let background: RGB
    let cursor: CursorStyle?

    init(_ cell: RenderSnapshotCell, in box: CGRect, palette: Palette, cursor: CursorStyle?) {
        self.cell = cell
        self.box = box
        self.cursor = cursor
        let style = cell.attribute.style
        var foreground = palette.resolve(cell.attribute.fg, foreground: true)
        var background = palette.resolve(cell.attribute.bg, foreground: false)
        let blockCursor = cursor == .blinkBlock || cursor == .steadyBlock
        let showsReversed = style.contains(.inverse) != blockCursor
        if showsReversed {
            swap(&foreground, &background)
        }
        self.foreground = style.contains(.dim) ? foreground.mixed(with: background) : foreground
        self.background = background
    }
}

private struct GlyphKey: Hashable {
    let text: String
    let bold: Bool
    let italic: Bool
}

private struct Glyph {
    enum Shape {
        case glyph(CTFont, CGGlyph)
        case line(CTLine)
    }

    let shape: Shape
    let advance: CGFloat
}
