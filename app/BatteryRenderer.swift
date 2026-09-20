// Menu bar battery icon renderer — ports the widget JS's pixel canvas, font, and geometry as-is
// (Builds CGImage directly instead of PNG encoding. Pixel placement matches the JS 1:1)
import Cocoa

struct BattItem {
  let label: String // "C5"·"CW"·"CF"·"X5"·"XW"·"X" — the first letter is the group (C/X)
  let remain: Double? // remaining % (nil means an empty capsule)
}

// 4x6 pixel font (big preset)
private let FONT46: [Character: [String]] = [
  "0": ["0110", "1001", "1001", "1001", "1001", "0110"],
  "1": ["0010", "0110", "0010", "0010", "0010", "0111"],
  "2": ["0110", "1001", "0010", "0100", "1000", "1111"],
  "3": ["1110", "0001", "0110", "0001", "1001", "0110"],
  "4": ["0010", "0110", "1010", "1111", "0010", "0010"],
  "5": ["1111", "1000", "1110", "0001", "1001", "0110"],
  "6": ["0110", "1000", "1110", "1001", "1001", "0110"],
  "7": ["1111", "0001", "0010", "0100", "0100", "0100"],
  "8": ["0110", "1001", "0110", "1001", "1001", "0110"],
  "9": ["0110", "1001", "1001", "0111", "0001", "0110"],
  "C": ["0110", "1001", "1000", "1000", "1001", "0110"],
  "X": ["1001", "1001", "0110", "0110", "1001", "1001"],
]
// 3x5 classic pixel font (small preset)
private let FONT35: [Character: [String]] = [
  "0": ["111", "101", "101", "101", "111"],
  "1": ["010", "110", "010", "010", "111"],
  "2": ["111", "001", "111", "100", "111"],
  "3": ["111", "001", "111", "001", "111"],
  "4": ["101", "101", "111", "001", "001"],
  "5": ["111", "100", "111", "001", "111"],
  "6": ["111", "100", "111", "101", "111"],
  "7": ["111", "001", "001", "001", "001"],
  "8": ["111", "101", "111", "101", "111"],
  "9": ["111", "101", "111", "001", "111"],
  "C": ["111", "100", "100", "100", "111"],
  "X": ["101", "101", "010", "101", "101"],
]

// Per-preset geometry (same values as the JS PRESET)
private struct Preset {
  let font: [Character: [String]]
  let adv: (Character) -> Int // letter spacing (in big, only '1' gets 4px kerning)
  let bw, bh, capw, gap, ggap, pad, lblgap, H, dy: Int
}

private let PRESET_BIG = Preset(font: FONT46, adv: { $0 == "1" ? 4 : 5 },
                                bw: 18, bh: 10, capw: 20, gap: 5, ggap: 10, pad: 2, lblgap: 3, H: 12, dy: 3)
private let PRESET_SMALL = Preset(font: FONT35, adv: { _ in 4 },
                                  // Compact menu-bar geometry: the 3x5 glyphs
                                  // remain readable at Retina scale without
                                  // competing with neighboring status icons.
                                  bw: 12, bh: 7, capw: 14, gap: 2, ggap: 5, pad: 1, lblgap: 1, H: 7, dy: 1)

let SIZE_FILE = "\(STATE_DIR)/.batt-size"
func currentBattSize() -> String {
  let s = (try? String(contentsOfFile: SIZE_FILE, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  // Small is the quieter default for a crowded macOS menu bar. Choosing Big
  // from Settings still persists and overrides this default.
  return s == "big" ? "big" : "small"
}

private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

// Logical pixel canvas (SCALE=2 — draws at 2x pixels for Retina)
private final class Canvas {
  static let SCALE = 2
  let wl: Int, hl: Int, w: Int, h: Int
  var buf: [UInt8]
  init(_ wl: Int, _ hl: Int) {
    self.wl = wl
    self.hl = hl
    w = wl * Canvas.SCALE
    h = hl * Canvas.SCALE
    buf = [UInt8](repeating: 0, count: w * h * 4)
  }

  func set(_ x: Int, _ y: Int, _ col: RGB) {
    if x < 0 || y < 0 || x >= wl || y >= hl { return }
    for dy in 0 ..< Canvas.SCALE {
      for dx in 0 ..< Canvas.SCALE {
        let px = ((y * Canvas.SCALE + dy) * w + (x * Canvas.SCALE + dx)) * 4
        buf[px] = col.r
        buf[px + 1] = col.g
        buf[px + 2] = col.b
        buf[px + 3] = 255
      }
    }
  }

  func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ col: RGB) {
    for j in 0 ..< rh { for i in 0 ..< rw { set(x + i, y + j, col) } }
  }

  // Rounded border leaving 1px open at the corners
  func stroke(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ col: RGB) {
    for i in 1 ..< max(1, rw - 1) {
      set(x + i, y, col)
      set(x + i, y + rh - 1, col)
    }
    for j in 1 ..< max(1, rh - 1) {
      set(x, y + j, col)
      set(x + rw - 1, y + j, col)
    }
  }
}

// Actual macOS battery indicator colors (Apple HIG system colors)
private func heatRemain(_ r: Double, dark: Bool) -> RGB {
  // Dark mode uses lower-saturation fills so the small batteries sit quietly
  // in the menu bar instead of looking like bright notification lights.
  if r <= 20 { return dark ? (126, 63, 60) : (255, 59, 48) }
  if r < 50 { return dark ? (132, 111, 52) : (255, 204, 0) }
  return dark ? (57, 112, 88) : (52, 199, 89)
}

// 100% remaining = golden battery (a two-tone gold distinct from the warning yellow)
func isGolden(_ remain: Double?) -> Bool { (remain ?? 0) >= 99.5 }
private func goldBase(_ dark: Bool) -> RGB { dark ? (145, 110, 42) : (255, 170, 0) }
private func goldHi(_ dark: Bool) -> RGB { dark ? (191, 164, 86) : (255, 214, 90) }

// Full span of the glint sweep — the length needed for the diagonal to fully cross the capsule
func batteryGlintSpan() -> Int {
  let p = currentBattSize() == "small" ? PRESET_SMALL : PRESET_BIG
  return p.bw + p.bh
}

// When altCol/boundaryX is set: if pixel x is left of the fill boundary, use altCol (contrast over the bright fill); if right, use col
@discardableResult
private func drawNum(_ cv: Canvas, _ p: Preset, _ x: Int, _ y: Int, _ str: String,
                     _ col: RGB, _ altCol: RGB? = nil, _ boundaryX: Int = 0) -> Int {
  var cx = x
  for ch in str {
    if let g = p.font[ch] {
      for (r, rowStr) in g.enumerated() {
        for (c, bit) in rowStr.enumerated() where bit == "1" {
          let px = cx + c
          if let alt = altCol, px < boundaryX { cv.set(px, y + r, alt) }
          else { cv.set(px, y + r, col) }
        }
      }
    }
    cx += p.adv(ch)
  }
  return cx
}

private func numW(_ p: Preset, _ s: String) -> Int { s.reduce(0) { $0 + p.adv($1) } - 1 }

// One capsule: border + remaining-fill + remaining number inside (100 included, always shown)
// 100% is two-tone gold; when glintX is set, a diagonal glint sweep passes over the gold capsule
private func drawCapsule(_ cv: Canvas, _ p: Preset, _ x: Int, _ midY: Int,
                         _ remain: Double?, _ ink: RGB, _ dark: Bool, _ glintX: Int?) {
  let by = midY - p.bh / 2
  cv.stroke(x, by, p.bw, p.bh, ink)
  cv.rect(x + p.bw, by + 3, 2, p.bh - 6, ink) // terminal
  guard let remain = remain else { return }
  let innerW = p.bw - 4
  let v = max(0, min(100, remain))
  let fw = Int((v / 100 * Double(innerW)).rounded())
  let golden = isGolden(remain)
  if fw > 0 {
    if golden {
      cv.rect(x + 2, by + 2, fw, p.bh - 4, goldBase(dark))
      cv.rect(x + 2, by + 2, fw, 2, goldHi(dark)) // top highlight
    } else {
      cv.rect(x + 2, by + 2, fw, p.bh - 4, heatRemain(remain, dark: dark))
    }
  }
  if golden, let g = glintX {
    for j in 0 ..< (p.bh - 4) {
      let gx = x + 2 + g - j // diagonal (down-left)
      if gx >= x + 2, gx < x + 2 + fw {
        cv.set(gx, by + 2 + j, (255, 255, 240))
        if gx + 1 < x + 2 + fw { cv.set(gx + 1, by + 2 + j, (255, 240, 170)) }
      }
    }
  }
  let s = String(Int(v.rounded()))
  let tx = x + (p.bw - numW(p, s)) / 2
  // Dark mode fills are muted, so use a soft light number instead of harsh black.
  let fillInk: RGB = dark ? (224, 238, 230) : (30, 30, 30)
  drawNum(cv, p, tx, midY - p.dy, s, ink, fillInk, x + 2 + fw)
}

// Draw one cat frame into the canvas (shares ink with the batteries; accents fixed)
private func drawCat(_ cv: Canvas, _ x: Int, _ y: Int, _ style: CatStyle, _ state: CatState, _ frame: Int, _ ink: RGB) {
  let grid = catFrame(style, state, frame)
  for (r, rowStr) in grid.enumerated() {
    for (c, ch) in rowStr.enumerated() {
      switch ch {
      case "A", "z": cv.set(x + c, y + r, ink)
      case "o": cv.set(x + c, y + r, (255, 150, 50))
      case "r": cv.set(x + c, y + r, (255, 70, 60))
      case "b": cv.set(x + c, y + r, (90, 180, 255))
      case "p": cv.set(x + c, y + r, (255, 150, 170)) // Nyan-style pink blush
      default: break
      }
    }
  }
}

// N capsules + group label (C/X) → NSImage (2x pixels; the caller scales down to the display size)
// With `cat`, a pixel cat runs at the left edge, facing its battery "finish line".
// Native macOS menu-bar treatment: system font, no pixel battery outlines.
// Each percentage is a quiet inline status value, so the widget reads like a
// first-party status item instead of a separate retro icon.
// STANDARD UI (2026-09-20): the system menu bar's own font (same face and size
// as the Apple clock — .AppleSystemUIFont 13pt), fixed width.
// The status item must never resize as the numbers change, so the image width
// is computed once from a worst-case template ("100" in every slot) and each
// value is padded with FIGURE SPACE (U+2007, one digit wide in the system font)
// so the glyphs sit in stable columns.
// Change only through an explicit source edit and local rebuild.
// Ask AppKit for the menu bar font rather than hard-coding a size, so the item
// tracks the clock if the system type scale ever changes. Tabular figures are
// layered on at the same size to keep the value columns from shifting.
private var STANDARD_STATUS_FONT_SIZE: CGFloat { NSFont.menuBarFont(ofSize: 0).pointSize }
private let STANDARD_STATUS_IMAGE_HEIGHT: CGFloat = 18 // < 22pt bar thickness, so AppKit never scales the image down
private let FIGURE_SPACE = "\u{2007}"
private let VALUE_SLOT_WIDTH = 3 // "100" — the widest value ever rendered

func renderBatteryImage(dark: Bool, items: [BattItem], glintX: Int? = nil,
                        cat: CatState? = nil, catFrameIndex: Int = 0) -> NSImage? {
  // Match the neighboring macOS status items rather than using a tiny custom
  // widget font; AppKit controls the type scale to match the native rhythm.
  // Keep the native macOS system font, but deliberately use a compact scale
  // so the status item stays subordinate to the other menu-bar controls.
  let font = NSFont.monospacedDigitSystemFont(ofSize: STANDARD_STATUS_FONT_SIZE, weight: .regular)
  let groupColor = dark ? NSColor(calibratedWhite: 0.82, alpha: 0.82)
                        : NSColor(calibratedWhite: 0.28, alpha: 0.88)
  let separatorColor = dark ? NSColor(calibratedWhite: 0.62, alpha: 0.42)
                            : NSColor(calibratedWhite: 0.35, alpha: 0.45)

  func valueColor(_ remain: Double?) -> NSColor {
    let r = remain ?? 0
    if r <= 20 { return dark ? NSColor(calibratedRed: 0.78, green: 0.38, blue: 0.36, alpha: 0.92)
                              : NSColor.systemRed }
    if r < 50 { return dark ? NSColor(calibratedRed: 0.72, green: 0.61, blue: 0.30, alpha: 0.92)
                              : NSColor.systemOrange }
    return dark ? NSColor(calibratedRed: 0.42, green: 0.72, blue: 0.61, alpha: 0.94)
                : NSColor.systemGreen
  }

  // Every value occupies a fixed 3-column slot (figure spaces are digit-width),
  // so 31 and 100 take exactly the same room and nothing shifts between ticks.
  func slot(_ remain: Double?) -> String {
    let raw = remain.map { String(Int($0.rounded())) } ?? "—"
    let padCount = max(0, VALUE_SLOT_WIDTH - raw.count)
    return String(repeating: FIGURE_SPACE, count: padCount) + raw
  }

  let result = NSMutableAttributedString(string: "")
  var previousGroup: Character?
  for item in items {
    let group = item.label.first!
    if group != previousGroup {
      if previousGroup != nil {
        result.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: separatorColor]))
      }
      result.append(NSAttributedString(string: String(group) + " ", attributes: [.font: font, .foregroundColor: groupColor]))
      previousGroup = group
    } else {
      result.append(NSAttributedString(string: " ", attributes: [.font: font]))
    }
    result.append(NSAttributedString(string: slot(item.remain), attributes: [.font: font, .foregroundColor: valueColor(item.remain)]))
  }

  let margin: CGFloat = 2
  let bounds = result.boundingRect(with: NSSize(width: 1000, height: 40),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
  let width = ceil(bounds.width) + margin * 2
  let image = NSImage(size: NSSize(width: width, height: STANDARD_STATUS_IMAGE_HEIGHT))
  image.lockFocus()
  let y = (STANDARD_STATUS_IMAGE_HEIGHT - ceil(bounds.height)) / 2
  result.draw(at: NSPoint(x: margin, y: y))
  image.unlockFocus()
  return image
}
