import SwiftUI

extension Notification.Name {
    static let acentoOpenSupport = Notification.Name("acento.openSupport")
}

enum SupportClient {
    enum Failure: Error {
        case rateLimited, rejected, unavailable
    }

    static func send(message: String, email: String, language: String) async throws {
        guard let url = URL(string: AppSignature.supportEndpoint), url.host != nil else { throw Failure.unavailable }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "message": message,
            "email": email,
            "appVersion": AppSignature.fullVersion,
            "macOS": AppSignature.macOSVersion,
            "language": language,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return
        case 429: throw Failure.rateLimited
        case 400: throw Failure.rejected
        default: throw Failure.unavailable
        }
    }
}

struct HelpPage: View {
    @Environment(\.locale) private var locale
    @State private var message = ""
    @State private var email = ""
    @State private var sending = false
    @State private var sent = false
    @State private var errorKey: String?

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var emailIsValid: Bool {
        trimmedEmail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
    private var canSend: Bool { trimmedMessage.count >= 3 && emailIsValid && !sending }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Help")
                        .font(AppFonts.figtree(size: 28, weight: .semibold))
                    Text("Tell us about a problem or share an idea. We read every message.")
                        .font(AppFonts.figtree(size: 14))
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Contact support").font(AppFonts.figtree(size: 16, weight: .semibold))
                Group {
                    if sent { confirmation } else { form }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 13))
            }
            .foregroundStyle(Color.inkPrimary)
            .padding(38)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your email").font(AppFonts.figtree(size: 13, weight: .medium))
                TextField("name@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .frame(maxWidth: 360)
                if !trimmedEmail.isEmpty && !emailIsValid {
                    Text("Enter a valid email.")
                        .font(AppFonts.figtree(size: 12))
                        .foregroundStyle(Color.errorText)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Message").font(AppFonts.figtree(size: 13, weight: .medium))
                TextEditor(text: $message)
                    .font(AppFonts.figtree(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(height: 200)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.cardBorder))
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text("What happened, or what would you like to suggest?")
                                .font(AppFonts.figtree(size: 13))
                                .foregroundStyle(Color.inkFaint)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: message) { _, value in
                        if value.count > 5000 { message = String(value.prefix(5000)) }
                    }
            }
            if let errorKey {
                Text(LocalizedStringKey(errorKey))
                    .font(AppFonts.figtree(size: 12))
                    .foregroundStyle(Color.errorText)
            }
            HStack(alignment: .center) {
                Text("The app and operating system versions are sent to help us fix issues.")
                    .font(AppFonts.figtree(size: 11))
                    .foregroundStyle(Color.inkFaint)
                Spacer()
                Button(action: send) {
                    Text(LocalizedStringKey(sending ? "Sending…" : "Send"))
                        .font(AppFonts.figtree(size: 12, weight: .semibold))
                        .foregroundStyle(canSend ? Color.onAccent : Color.inkSecondary)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(canSend ? Color.inkPrimary : Color.disabledBackground, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .pointerCursor(canSend)
            }
        }
    }

    private var confirmation: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.activeText)
            VStack(alignment: .leading, spacing: 6) {
                Text("Message sent")
                    .font(AppFonts.figtree(size: 15, weight: .semibold))
                Text("Thanks for writing. We'll reply to your email soon.")
                    .font(AppFonts.figtree(size: 13))
                    .foregroundStyle(Color.inkSecondary)
            }
            Spacer()
            CardPrimaryButton(title: "Send another message", muted: true) {
                message = ""
                sent = false
            }
        }
    }

    private func send() {
        guard canSend else { return }
        sending = true
        errorKey = nil
        let language = locale.language.languageCode?.identifier ?? "unknown"
        Task {
            do {
                try await SupportClient.send(message: trimmedMessage, email: trimmedEmail, language: language)
                sent = true
            } catch SupportClient.Failure.rateLimited {
                errorKey = "Too many messages. Please wait a minute and try again."
            } catch SupportClient.Failure.rejected {
                errorKey = "Check your email and message, then try again."
            } catch {
                errorKey = "Couldn't send your message. Check your connection and try again."
            }
            sending = false
        }
    }
}
