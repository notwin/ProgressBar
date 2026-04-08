// ═══════════════════════════════════════════════════════════════════
// 主题系统（6 套差异化高品质配色）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct ThemeColors {
    let id: String; let name: String
    let bg: Color; let surface: Color; let elevated: Color; let border: Color
    let t1: Color; let t2: Color; let t3: Color
    let accent: Color; let orange: Color; let red: Color; let green: Color
    let purple: Color
}

let THEMES: [ThemeColors] = [
    // 自动 — 跟随系统，使用 Obsidian 配色
    ThemeColors(id: "auto", name: "自动",
        bg: Color(hex: "0C0E14"), surface: Color(hex: "151823"), elevated: Color(hex: "1E2235"),
        border: Color(hex: "2A2F45"), t1: Color(hex: "ECEEF4"), t2: Color(hex: "8B90A5"),
        t3: Color(hex: "545972"), accent: Color(hex: "6E7BF5"), orange: Color(hex: "F0A45B"),
        red: Color(hex: "E5534B"), green: Color(hex: "3FB87F"), purple: Color(hex: "A78BFA")),
    // 黑曜石 — 深蓝黑底，柔和靛蓝，灵感 Linear
    ThemeColors(id: "obsidian", name: "黑曜石",
        bg: Color(hex: "0C0E14"), surface: Color(hex: "151823"), elevated: Color(hex: "1E2235"),
        border: Color(hex: "2A2F45"), t1: Color(hex: "ECEEF4"), t2: Color(hex: "8B90A5"),
        t3: Color(hex: "545972"), accent: Color(hex: "6E7BF5"), orange: Color(hex: "F0A45B"),
        red: Color(hex: "E5534B"), green: Color(hex: "3FB87F"), purple: Color(hex: "A78BFA")),
    // 深渊 — 深海青绿，沉浸感，灵感 Arc
    ThemeColors(id: "abyss", name: "深渊",
        bg: Color(hex: "091A22"), surface: Color(hex: "0F2A36"), elevated: Color(hex: "163846"),
        border: Color(hex: "1E4A5C"), t1: Color(hex: "E4F0F5"), t2: Color(hex: "7FA8B8"),
        t3: Color(hex: "4D7A8C"), accent: Color(hex: "22C5E0"), orange: Color(hex: "E8A84C"),
        red: Color(hex: "E06B6B"), green: Color(hex: "2DD4A8"), purple: Color(hex: "9B8AFB")),
    // 砂岩 — 暖色大地调，皮革质感
    ThemeColors(id: "sandstone", name: "砂岩",
        bg: Color(hex: "1C1814"), surface: Color(hex: "272017"), elevated: Color(hex: "33291E"),
        border: Color(hex: "4A3D2E"), t1: Color(hex: "F0E6D6"), t2: Color(hex: "B8A68E"),
        t3: Color(hex: "7D6F5C"), accent: Color(hex: "E89B4C"), orange: Color(hex: "D4763A"),
        red: Color(hex: "CC5C48"), green: Color(hex: "6AAB62"), purple: Color(hex: "A882C5")),
    // 霓虹 — 赛博朋克，暗紫底+荧光色
    ThemeColors(id: "neon", name: "霓虹",
        bg: Color(hex: "0A0A12"), surface: Color(hex: "12121F"), elevated: Color(hex: "1A1A2E"),
        border: Color(hex: "2D2B4A"), t1: Color(hex: "F0EDFF"), t2: Color(hex: "8C89AA"),
        t3: Color(hex: "5A5775"), accent: Color(hex: "E040FB"), orange: Color(hex: "FF9E44"),
        red: Color(hex: "FF4D6A"), green: Color(hex: "00E599"), purple: Color(hex: "7C4DFF")),
    // 霜冻 — 柔和冷色调，灵感 Nord/Catppuccin
    ThemeColors(id: "frost", name: "霜冻",
        bg: Color(hex: "1E2030"), surface: Color(hex: "262940"), elevated: Color(hex: "2E3250"),
        border: Color(hex: "3A3E5C"), t1: Color(hex: "E4E8F7"), t2: Color(hex: "A0A5C0"),
        t3: Color(hex: "6B7094"), accent: Color(hex: "89B4FA"), orange: Color(hex: "FAB387"),
        red: Color(hex: "F38BA8"), green: Color(hex: "A6E3A1"), purple: Color(hex: "CBA6F7")),
    // 纸墨 — 高级浅色，暖白底+钴蓝，灵感 Things 3
    ThemeColors(id: "paper", name: "纸墨",
        bg: Color(hex: "F8F7F4"), surface: Color.white, elevated: Color.white,
        border: Color(hex: "E4E2DC"), t1: Color(hex: "1A1A1A"), t2: Color(hex: "6B6B6B"),
        t3: Color(hex: "9E9E9E"), accent: Color(hex: "2563EB"), orange: Color(hex: "D97706"),
        red: Color(hex: "DC2626"), green: Color(hex: "16A34A"), purple: Color(hex: "7C3AED")),
]

/// 扩展 Color 支持 HEX 字符串初始化（如 "ff9500"）
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0; Scanner(string: h).scanHexInt64(&int)
        let r, g, b: Double
        if h.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        } else { r = 0; g = 0; b = 0 }
        self.init(red: r, green: g, blue: b)
    }
}
