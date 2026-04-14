// ═══════════════════════════════════════════════════════════════════
// 快捷悬浮输入窗（NSPanel + NSHostingView），全局热键/菜单栏呼出
// ═══════════════════════════════════════════════════════════════════

import AppKit
import SwiftUI

/// 允许 panel 成为 key window（否则 TextField 无法接收输入）
final class QuickInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickInputWindowController: NSObject, NSWindowDelegate {
    static let shared = QuickInputWindowController()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private weak var state: AppState?

    func configure(state: AppState) {
        self.state = state
    }

    func windowDidResignKey(_ notification: Notification) {
        // 点击其他窗口/桌面 → 悬浮窗失去 key 状态 → 自动关闭
        hide()
    }

    func toggle() {
        if let p = panel, p.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let state = state else { return }

        if panel == nil {
            let size = NSSize(width: 640, height: 80)
            let p = QuickInputPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = false
            // 不用 hidesOnDeactivate：app 在后台时会错误隐藏 panel；改由 windowDidResignKey 手动关
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.delegate = self
            let view = QuickInputView(
                onDismiss: { [weak self] in self?.hide() },
                onSizeChange: { [weak self] size in self?.adjustPanelSize(to: size) }
            ).environmentObject(state)
            let host = NSHostingView(rootView: view)
            host.autoresizingMask = [.width, .height]
            p.contentView = host
            panel = p
        }

        guard let p = panel else { return }

        // 居中于当前屏（鼠标所在屏）
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            let size = p.frame.size
            let origin = NSPoint(
                x: f.midX - size.width / 2,
                y: f.midY + f.height * 0.15 - size.height / 2
            )
            p.setFrameOrigin(origin)
        }

        installKeyMonitor()
        // 不调 NSApp.activate：保持 app 后台状态，只让 panel 成为 key；
        // nonactivatingPanel + canBecomeKey=true 能在 app 不激活时独立接收键盘
        // fade-in 动画：0 → 1 用 0.12s
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
    }

    /// SwiftUI 内容尺寸变化 → 调整 panel 以贴合（保持顶部位置不变）
    private func adjustPanelSize(to size: CGSize) {
        guard let p = panel, size.width > 0, size.height > 0 else { return }
        let current = p.frame
        let newWidth = max(size.width, 640)
        let newHeight = max(size.height, 80)
        // top-anchored resize（macOS frame 原点在左下）
        let newFrame = NSRect(
            x: current.origin.x,
            y: current.origin.y + current.height - newHeight,
            width: newWidth,
            height: newHeight
        )
        if abs(newFrame.height - current.height) < 0.5 && abs(newFrame.width - current.width) < 0.5 {
            return
        }
        p.setFrame(newFrame, display: true, animate: false)
    }

    func hide() {
        guard let p = panel, p.isVisible else {
            removeKeyMonitor()
            return
        }
        removeKeyMonitor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in
            p?.orderOut(nil)
            p?.alphaValue = 1
        })
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel?.isKeyWindow == true else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘] / ⌘[ 切换分区（下一个/上一个）——window 级拦截，绕过 TextField 吞键
            if mods == .command, let chars = event.charactersIgnoringModifiers {
                if chars == "]" {
                    NotificationCenter.default.post(name: .quickInputCycleSection, object: nil, userInfo: ["direction": 1])
                    return nil
                }
                if chars == "[" {
                    NotificationCenter.default.post(name: .quickInputCycleSection, object: nil, userInfo: ["direction": -1])
                    return nil
                }
            }
            // Esc 交由 SwiftUI QuickInputView 处理（需两段语义：pin → unpin，否则关窗）
            // ⌘W 强制关闭（fallback）
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
                self.hide()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}
