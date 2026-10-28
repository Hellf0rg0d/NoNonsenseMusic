import SwiftUI

/// The server to use, and your account on it (Account.signIn). The address is kept as the Mac app keeps it.
struct SignInScreen: View {
    @Environment(Account.self) private var account
    @AppStorage("serverURL") private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var creating = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("music.example.com", text: $server)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of your NoNonsenseMusic server. The app has none of its own.")
                }
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(creating ? .newPassword : .password)
                    Toggle("New account", isOn: $creating)
                }
                if let problem = problem ?? account.notice {
                    Text(problem).foregroundStyle(.red)
                }
                Button {
                    Task { await go() }
                } label: {
                    HStack {
                        Text(creating ? "Create account" : "Sign in")
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(working || server.trimmingCharacters(in: .whitespaces).isEmpty || username.isEmpty || password.isEmpty)
            }
            .navigationTitle("NoNonsenseMusic")
        }
    }

    private func go() async {
        working = true
        defer { working = false }
        server = API.address(server)                  // "music.example.com" becomes https://music.example.com
        problem = await account.signIn(username, password, create: creating)
    }
}
