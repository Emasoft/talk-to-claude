import SwiftUI

/// In-app reference for PREFIX MODE — the "command"-prefixed voice grammar.
/// This screen MIRRORS `server/voice_commands.py` (the nested scope-stack
/// interpreter). When the grammar changes on the server, update this screen too —
/// it documents exactly what the interpreter does, nothing aspirational.
///
/// Pushed onto the Settings navigation stack, so it carries no NavigationStack /
/// Done button of its own (the back button handles dismissal).
struct PrefixGrammarHelpView: View {
    var body: some View {
        List {
            Section {
                Text("With **Require “command” prefix** ON, everything you say is typed **literally**. A command fires only when you say **“command”** first — so ordinary dictation is never eaten.")
                    .font(.callout)
            } header: {
                Text("Literal by default")
            }

            Section {
                row("command enter", "⏎")
                row("command arrow up", "↑")
                row("command slash", "/")
                row("command space", "␣")
            } header: {
                Text("One command")
            } footer: {
                Text("“command” + ONE command, then you’re back to literal text. Each command needs its own “command” (e.g. “command enter” … “command slash”).")
            }

            Section {
                row("command number start  four five  number stop", "45")
                row("command caps start  deploy now  caps stop", "DEPLOY NOW")
                row("command spell start  al em er  spell stop", "lmr")
                row("command delete start  world  delete stop", "erase “world”")
                row("command replace start  cat  replace with  dog  replace stop", "cat → dog")
            } header: {
                Text("Mode block — ONE argument")
            } footer: {
                Text("“command <MODE> start … <MODE> stop” is one self-contained unit: no “command” inside, and the closing “<MODE> stop” needs no “command”.\n\nMODES:  caps · spell · number · delete · replace")
            }

            Section {
                row("command caps start  spell start  al em er  spell stop  caps stop", "LMR")
            } header: {
                Text("Modes nest")
            } footer: {
                Text("CAPS wraps SPELL, so the spelled letters come out upper-cased. It’s still ONE argument — one block, however deep it nests.")
            }

            Section {
                row("command start  backspace twelve times  command stop", "⌫ × 12")
                row("command start  backword two  command stop", "delete 2 words")
                row("command start  number start one number stop  caps start spell start al em er spell stop caps stop  command stop", "1LMR")
            } header: {
                Text("Region — MANY arguments")
            } footer: {
                Text("“command start … command stop” holds as many commands/blocks as you like, and they concatenate.\n\n• “<N> times” repeats a command — REGION only.\n• “backword <N>” deletes N whole words.")
            }

            Section {
                Text("**START = (    STOP = )**\nEvery START opens a scope; every STOP closes the **innermost** open one (last-in, first-out). A bare “stop” with nothing open is just the word “stop”.")
                    .font(.callout)
            } header: {
                Text("The rule")
            }

            Section {
                Text("Italian works too:  comando · inizio · fine · maiuscolo · compita · numero · cancella · sostituzione.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Command grammar")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One "say this → get that" reference row.
    @ViewBuilder
    private func row(_ say: String, _ out: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(say)
                .font(.footnote.monospaced())
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(out)
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 1)
    }
}
