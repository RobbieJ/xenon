import SwiftUI

/// Five screens, see docs/research/05 §7. Kept deliberately plain until the design pass in phase 4.
struct OnboardingView: View {
    let onDone: () -> Void
    @State private var page = 0

    private let pages: [(title: String, body: String, symbol: String)] = [
        ("Talk normally in a loud room.", "Sotto sends your voice from your AirPods straight to your partner's AirPods over a direct link between your iPhones. No Wi-Fi network, no mobile signal.", "airpods.pro"),
        ("Put your AirPods in.", "Switch on Noise Cancellation. Turn off Conversation Awareness and Adaptive Audio for the conversation, or your partner will keep getting quieter every time you speak.", "ear"),
        ("Microphone access.", "Your voice is sent live to your partner only. Nothing is recorded or stored.", "mic"),
        ("Pairing.", "Hold your phones near each other. One of you taps Pair; the other confirms the code. You only do this once.", "iphone.gen3.radiowaves.left.and.right"),
        ("You're set.", "Your own voice will sound a little muffled with Noise Cancellation on. That is normal; you do not need to raise it.", "checkmark.circle"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: pages[page].symbol)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(pages[page].title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
            Text(pages[page].body).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            HStack {
                ForEach(pages.indices, id: \.self) { i in
                    Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                }
            }
            Button(page == pages.count - 1 ? "Start" : "Continue") {
                if page == pages.count - 1 { onDone() } else { page += 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
    }
}
