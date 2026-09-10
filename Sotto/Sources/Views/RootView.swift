import SwiftUI
import SottoCore
import SottoTransport

struct RootView: View {
    @Environment(SessionCoordinator.self) private var session
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        NavigationStack {
            Group {
                if !onboardingComplete {
                    OnboardingView { onboardingComplete = true }
                } else {
                    switch session.state {
                    case .idle, .ended:
                        HomeView()
                    case .discovering, .pairing, .connecting, .reconnecting:
                        ConnectingView()
                    case .connected:
                        ConversationView()
                    }
                }
            }
            .navigationTitle("Sotto")
        }
    }
}

struct HomeView: View {
    @Environment(SessionCoordinator.self) private var session
    @State private var impaired = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "airpods.pro")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Talk normally in a loud room.")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if case .ended(let reason) = session.state {
                Text(label(for: reason)).foregroundStyle(.secondary)
            }
            if let err = session.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            Toggle("Simulate a poor link", isOn: $impaired)
                .padding(.horizontal)
            Button {
                var model = ImpairmentModel.ideal
                if impaired {
                    model.baseDelayMilliseconds = 20
                    model.jitterMilliseconds = 60
                    model.lossProbability = 0.05
                    model.connectionIntervalMilliseconds = 30
                }
                session.reset()
                session.startLoopback(model: model)
            } label: {
                Label("Start self-test (loopback)", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Pair with a partner") {}
                .disabled(true)
            Text("Partner pairing arrives in phase 2 (Wi-Fi Aware and Bluetooth).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func label(for reason: SessionEndReason) -> String {
        switch reason {
        case .userEnded: return "Conversation ended."
        case .partnerEnded: return "Your partner ended the conversation."
        case .linkLost: return "The link was lost."
        case .audioUnavailable: return "AirPods were disconnected."
        case .failed(let why): return "Failed: \(why)"
        }
    }
}

struct ConnectingView: View {
    @Environment(SessionCoordinator.self) private var session
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Connecting…")
            Button("Cancel", role: .cancel) { session.end() }
        }
    }
}
