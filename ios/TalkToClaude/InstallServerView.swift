import SwiftUI
import UIKit

/// The public, open-source repository for the Mac side of Talk to Claude.
let kRepoURL = "https://github.com/Emasoft/talk-to-claude"

/// The single command a user pastes into a Mac Terminal to install the free,
/// open-source speech-recognition server. Shown verbatim in onboarding and in
/// Settings → "Install the ASR for free on your Mac."
let kInstallOneLiner =
    "curl -fsSL https://raw.githubusercontent.com/Emasoft/talk-to-claude/main/install.sh | bash"

// MARK: - Reusable pieces

/// The one-liner in a monospaced box with a Copy button.
private struct OneLinerBox: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kInstallOneLiner)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button {
                UIPasteboard.general.string = kInstallOneLiner
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation { copied = true }
            } label: {
                Label(copied ? "Copied!" : "Copy command",
                      systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One labelled bullet row (icon + text).
private struct Bullet: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint).frame(width: 22)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The shared "how to install the free Mac server" body — used by both the
/// first-run onboarding and the Settings sheet.
private struct InstallBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("100% free — now and always", systemImage: "gift.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("No fees, no subscriptions, no in-app purchases, no ads. The app "
                     + "is free and the Mac server is open source.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("On your Mac, paste this one line into Terminal:")
                    .font(.subheadline.weight(.semibold))
                OneLinerBox()
            }

            VStack(alignment: .leading, spacing: 10) {
                Bullet(icon: "shippingbox.fill",
                       text: "Installs everything automatically — including the free, "
                           + "MIT-licensed Whisper speech model. Nothing else to set up.")
                Bullet(icon: "lock.shield.fill",
                       text: "Runs entirely on your Mac. Your voice never leaves your "
                           + "own network.")
                Bullet(icon: "desktopcomputer",
                       text: "Requires macOS 15 (Sequoia) or newer, and Tailscale signed "
                           + "in on both your Mac and this device.")
            }

            Link(destination: URL(string: kRepoURL)!) {
                Label("View the open-source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.subheadline.weight(.semibold))
            }

            DisclaimerText()
        }
    }
}

/// Compact in-app legal note. The full, worldwide version lives in the README /
/// repository (Legal & disclaimers) and PRIVACY.md.
private struct DisclaimerText: View {
    var body: some View {
        Text("Talk to Claude is an independent, open-source companion app. It is not "
             + "affiliated with, endorsed by, or sponsored by Anthropic; \u{201C}Claude\u{201D} "
             + "is a trademark of Anthropic, used here only to describe interoperability. "
             + "You bring your own Claude CLI and run the server on your own Mac. The "
             + "software is provided \u{201C}as is\u{201D}, without warranty of any kind, to the "
             + "extent permitted by law; this does not limit any non-waivable consumer "
             + "rights you may have. See the repository for full terms and the privacy policy.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Settings sheet

/// Settings → "Install the ASR for free on your Mac."
struct InstallServerView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { InstallBody().padding() }
                .navigationTitle("Install on your Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - First-launch onboarding

/// Shown once, on first launch, so the user knows the app needs a free companion
/// server on their Mac. `onDone` flips the persisted "did onboard" flag.
struct OnboardingView: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 40)).foregroundStyle(.tint)
                        Text("Welcome to Talk to Claude")
                            .font(.largeTitle.weight(.bold))
                        Text("Speak instead of type. Your voice streams to your own Mac, "
                             + "is transcribed locally with Whisper, and is typed into your "
                             + "Claude CLI session — hands-free.")
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    Text("One quick setup step")
                        .font(.title3.weight(.semibold))
                    Text("Talk to Claude needs a small, free helper running on your Mac. "
                         + "It takes one command to install — you only do this once.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    InstallBody()

                    Button { onDone() } label: {
                        Text("Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)

                    Text("You can see this command again any time in "
                         + "Settings → \u{201C}Install the ASR for free on your Mac.\u{201D}")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)   // must tap Get Started
    }
}
