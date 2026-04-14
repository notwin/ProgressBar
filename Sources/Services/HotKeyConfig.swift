// ═══════════════════════════════════════════════════════════════════
// 全局快捷键配置（Carbon keyCode + modifiers），UserDefaults 持久化
// ═══════════════════════════════════════════════════════════════════

import AppKit
import Carbon.HIToolbox

struct HotKeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonMods: UInt32

    static let `default` = HotKeyConfig(
        keyCode: UInt32(kVK_Space),
        carbonMods: UInt32(controlKey | optionKey)
    )

    var displayString: String {
        var s = ""
        if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonMods & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonMods & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonMods & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += HotKeyConfig.keyName(for: keyCode)
        return s
    }

    // ── UserDefaults ────────────────────────────────────────────
    private static let defaultsKey = "hotkey.quickInput"

    static func load() -> HotKeyConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let cfg = try? JSONDecoder().decode(HotKeyConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // ── NSEvent → Carbon modifiers ──────────────────────────────
    static func carbonMods(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    /// 纯修饰符键（没有真实字符，不应作为 hotkey 主键）
    static func isModifierKeyCode(_ keyCode: UInt32) -> Bool {
        let kc = Int(keyCode)
        return kc == kVK_Shift || kc == kVK_RightShift
            || kc == kVK_Control || kc == kVK_RightControl
            || kc == kVK_Option || kc == kVK_RightOption
            || kc == kVK_Command || kc == kVK_Function
            || kc == kVK_CapsLock
    }

    // ── keyCode → 显示名 ───────────────────────────────────────
    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "↵", kVK_Tab: "⇥",
        kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func keyName(for keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? "Key\(keyCode)"
    }
}
