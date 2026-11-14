import AppKit
import T3ProxyCore

/// Offline diagnostic artwork, using the production layers. No monitor, accounts or server connection.
/// Everything here is synthetic: states are set directly and effects are replayed on a loop.
@MainActor public enum AgentIconPreview {
    private struct Example {
        let name: String; let state: AgentActivity; var attention = false
        var effect: AgentEffect? = nil; var reduced = false; var light = false
    }

    public static func show() -> NSWindow {
        let columns = 7
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 12 + columns * 160, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "T3 Proxy · Synthetic icon previews (not live events; streaming is artwork only)"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.045, green: 0.055, blue: 0.07, alpha: 1)
        let examples: [Example] = [
            Example(name: "Idle · dark", state: .idle),
            Example(name: "Working", state: .working),
            Example(name: "Streaming¹", state: .streaming),
            Example(name: "Subagents", state: .subagent),
            Example(name: "Needs you", state: .waiting, attention: true),
            Example(name: "Working + needs you", state: .streaming, attention: true),
            Example(name: "Working · light bar", state: .working, light: true),
            Example(name: "Report (loop)", state: .working, effect: .report),
            Example(name: "Finished (loop)", state: .idle, effect: .finished),
            Example(name: "Error (loop)", state: .idle, effect: .error),
            Example(name: "Reduce · working", state: .subagent, reduced: true),
            Example(name: "Reduce · needs you", state: .waiting, attention: true, reduced: true),
            Example(name: "Reduce · error", state: .idle, effect: .error, reduced: true),
            Example(name: "Idle · light", state: .idle, light: true),
        ]
        var loops: [(AgentCoreView, Example)] = []
        for (index, example) in examples.enumerated() {
            let x = 12 + (index % columns) * 160, y = 262 - (index / columns) * 230
            let tile = NSView(frame: NSRect(x: x, y: y, width: 152, height: 212))
            tile.wantsLayer = true; tile.layer?.cornerRadius = 12
            tile.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).cgColor
            if example.light {
                tile.appearance = NSAppearance(named: .aqua)
                tile.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1).cgColor
            }
            for (size, bottom) in [(CGFloat(18), CGFloat(162)), (CGFloat(104), CGFloat(40))] {
                let frame = NSRect(x: (152 - size) / 2, y: bottom, width: size, height: size)
                if example.state == .idle && example.effect == nil {
                    let image = NSImageView(frame: frame); image.image = AgentCoreView.templateImage()
                    image.imageScaling = .scaleProportionallyUpOrDown; tile.addSubview(image)
                } else {
                    let view = AgentCoreView(frame: frame); tile.addSubview(view)
                    view.update(state: example.state, attention: example.attention, reduceMotion: example.reduced)
                    view.layoutSubtreeIfNeeded()
                    if let effect = example.effect {
                        if example.reduced { view.play(effect, reduceMotion: true) } else { loops.append((view, example)) }
                    }
                }
            }
            let label = NSTextField(labelWithString: example.name)
            label.alignment = .center; label.font = .systemFont(ofSize: 11, weight: .medium)
            label.frame = NSRect(x: 0, y: 10, width: 152, height: 18); tile.addSubview(label)
            window.contentView?.addSubview(tile)
        }
        let note = NSTextField(labelWithString: "Synthetic: effects replay every 2.4 s, restoring the base state after 1.6 s like the status item. ¹Streaming is artwork only.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 14, y: 6, width: 12 + columns * 160 - 28, height: 16)
        window.contentView?.addSubview(note)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Diagnostic loop only; the real status item has no frame or repeat timer.
        Task { @MainActor in
            while window.isVisible {
                loops.forEach { $0.0.play($0.1.effect!, reduceMotion: false) }
                try? await Task.sleep(for: .seconds(1.6))
                loops.forEach { $0.0.update(state: $0.1.state, attention: $0.1.attention, reduceMotion: false) }
                try? await Task.sleep(for: .seconds(0.8))
            }
            NSApp.terminate(nil)
        }
        return window
    }
}
