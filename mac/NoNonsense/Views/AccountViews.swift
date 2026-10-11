import SwiftUI
import UniformTypeIdentifiers

/// The ten recovery codes, shown once: after sign-up, and after Settings › Account makes a new set. The server keeps
/// only their hashes, so this sheet is the only place they can be read. Done is enabled once the codes have been
/// copied or saved, so the sheet is not closed before they are kept somewhere.
struct RecoveryCodesSheet: View {
    let codes: [String]
    let username: String
    let done: () -> Void
    @State private var copied = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Save Your Recovery Codes").textStyle(.title2, weight: .semibold)
                Text("If you forget your password, a code lets you set a new one. Each code works once, and they are not shown again.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(horizontalSpacing: 28, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: codes.count, by: 2)), id: \.self) { i in
                    GridRow {
                        Text(codes[i])
                        if i + 1 < codes.count { Text(codes[i + 1]) }
                    }
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10, style: .continuous))
            .selfTestFrame("recovery.codes")
            HStack {
                Button { copy() } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { save() } label: {
                    Label(saved ? "Saved" : "Save…", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!copied && !saved)
                    .help(copied || saved ? "" : "Copy or save the codes first")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    /// The codes as a short text file: the app, the account, then one code per line.
    private var text: String {
        "NoNonsenseMusic recovery codes for \(username)\n\n" + codes.joined(separator: "\n") + "\n"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NoNonsenseMusic Recovery Codes.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { saved = true }
    }
}

/// Settings › Account › New Recovery Codes: the password again, then the new set in RecoveryCodesSheet.
struct NewRecoveryCodesSheet: View {
    let cancel: () -> Void
    let made: ([String]) -> Void
    @Environment(Account.self) private var account
    @State private var password = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Recovery Codes").textStyle(.headline)
            Text("Your current codes stop working.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
                .onChange(of: password) { problem = nil }
            if let problem {
                Text(problem).textStyle(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(working ? "Making…" : "Make New Codes", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func go() {
        guard !password.isEmpty, !working else { return }
        working = true
        Task {
            switch await account.replaceRecoveryCodes(password: password) {
            case .success(let codes): made(codes)
            case .failure(let failure): problem = failure.text
            }
            working = false
        }
    }
}
