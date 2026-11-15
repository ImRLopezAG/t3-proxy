import AppKit
import T3ProxyCore

/// Offline diagnostic artwork, using the production layers. No monitor, accounts or server connection.
/// Everything here is synthetic: states are set directly and effects are replayed on a loop.
@MainActor public enum AgentIconPreview {
    private struct Example {
        let name: String; let state: AgentActivity; var attention = false
        var effect: AgentEffect? = nil; var reduced = false; var light = false
        var working: Bool? = nil; var transitions = false; var customActive: String? = nil
        var snoozed = 0; var waiting = false
        var activity: AgentActivityUpdate {
            AgentActivityUpdate(state: state, needsAttention: attention, hasWorkingThread: working,
                                snoozedThreadCount: snoozed, hasWaitingThread: waiting)
        }
    }

    public static func show() -> NSWindow {
        let columns = 7
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 12 + columns * 160, height: 730),
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
            Example(name: "Work + children + needs you", state: .subagent, attention: true, working: true),
            Example(name: "Waiting on background", state: .subagent, working: false),
            Example(name: "Mixed + error (loop)", state: .subagent, attention: true, effect: .error, working: true),
            Example(name: "Transitions (loop)", state: .working, transitions: true),
            Example(name: "Reduce · mixed", state: .subagent, attention: true, reduced: true, working: true),
            Example(name: "Snoozed · no motion", state: .idle, snoozed: 2),
            Example(name: "Work + waiting + snoozed", state: .subagent, working: true, snoozed: 1, waiting: true),
        ]
        var loops: [(AgentCoreView, Example)] = []
        var transitions: [AgentCoreView] = []
        for (index, example) in examples.enumerated() {
            let x = 12 + (index % columns) * 160, y = 492 - (index / columns) * 230
            let tile = NSView(frame: NSRect(x: x, y: y, width: 152, height: 212))
            tile.wantsLayer = true; tile.layer?.cornerRadius = 12
            tile.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).cgColor
            if example.light {
                tile.appearance = NSAppearance(named: .aqua)
                tile.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1).cgColor
            }
            for (size, bottom) in [(CGFloat(18), CGFloat(162)), (CGFloat(104), CGFloat(40))] {
                let frame = NSRect(x: (152 - size) / 2, y: bottom, width: size, height: size)
                do {
                    let view = AgentCoreView(frame: frame); tile.addSubview(view)
                    if let custom = example.customActive {
                        var preferences = AgentIconPreferences()
                        preferences.colorMode = .custom; preferences.activeColor = AgentIconColor(hex: custom)
                        preferences.attentionColor = AgentIconColor(hex: "FF9924"); preferences.errorColor = AgentIconColor(hex: "FF382E")
                        view.configure(preferences)
                    }
                    view.update(example.activity, reduceMotion: example.reduced)
                    view.layoutSubtreeIfNeeded()
                    if example.transitions { transitions.append(view) }
                    if let effect = example.effect {
                        if example.reduced { view.play(effect, reduceMotion: true) } else { loops.append((view, example)) }
                    }
                }
            }
            let label = NSTextField(labelWithString: example.name)
            label.alignment = .center; label.font = .systemFont(ofSize: 10, weight: .medium)
            label.frame = NSRect(x: 0, y: 10, width: 152, height: 18); tile.addSubview(label)
            window.contentView?.addSubview(tile)
        }
        let note = NSTextField(labelWithString: "Synthetic: effects loop every 2.4 s; transitions change every 0.8 s. Colour channels follow icon preferences. ¹Streaming is artwork only.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 14, y: 6, width: 12 + columns * 160 - 28, height: 16)
        window.contentView?.addSubview(note)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Diagnostic loop only; the real status item has no frame or repeat timer.
        Task { @MainActor in
            let states: [AgentActivityUpdate] = [
                .init(state: .working), .init(state: .working, needsAttention: true),
                .init(state: .subagent, needsAttention: true, hasWorkingThread: true),
                .init(state: .subagent, hasWorkingThread: true, snoozedThreadCount: 1, hasWaitingThread: true),
                .init(state: .subagent, hasWorkingThread: false), .init(state: .waiting, needsAttention: true),
                .init(state: .idle),
            ]
            var index = 0
            while window.isVisible {
                transitions.forEach { $0.update(states[index % states.count], reduceMotion: false) }
                index += 1
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
        Task { @MainActor in
            while window.isVisible {
                loops.forEach { $0.0.play($0.1.effect!, reduceMotion: false) }
                try? await Task.sleep(for: .seconds(1.6))
                loops.forEach { $0.0.finishEffect() }
                try? await Task.sleep(for: .seconds(0.8))
            }
            NSApp.terminate(nil)
        }
        return window
    }
}
