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
    @State private var showPairOptions = false

    var body: some View {
        @Bindable var session = session
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
            if !session.partners.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Partners").font(.footnote).foregroundStyle(.secondary)
                    ForEach(session.partners) { p in
                        HStack {
                            Text(p.displayName)
                            Spacer()
                            Button("Forget", role: .destructive) { session.forget(p) }.font(.footnote)
                        }
                    }
                }
                .padding(.horizontal)
            }
            Spacer()
            #if canImport(WiFiAware)
            Button {
                session.reset()
                session.talk()
            } label: {
                Label("Talk", systemImage: "phone.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.partners.isEmpty || !session.isWiFiAwareSupported)
            Button("Pair with a partner") { showPairOptions = true }
                .disabled(!session.isWiFiAwareSupported)
                .confirmationDialog("Only one of you needs to show a code.", isPresented: $showPairOptions, titleVisibility: .visible) {
                    Button("Show a code") { session.reset(); session.pairAsHost() }
                    Button("Enter a code") { session.reset(); session.pairAsGuest() }
                }
            #endif
            #if canImport(CoreBluetooth)
            Button {
                session.reset()
                session.talkOverBluetooth()
            } label: {
                Label("Talk over Bluetooth only", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("For Airplane Mode with Wi-Fi off, or iPhones without Wi-Fi Aware. Lower quality; both phones tap this.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            #endif
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
            .buttonStyle(.bordered)
        }
        .padding()
        #if canImport(WiFiAware)
        .sheet(item: $session.pairingSheet) { sheet in
            NavigationStack {
                Group {
                    switch sheet {
                    case .host: PairingHostView { session.lastError = $0 }
                    case .guest: PairingPickerView(onPicked: { session.guestPicked($0) }, onError: { session.lastError = $0 })
                    }
                }
                .navigationTitle(sheet == .host ? "Show this code" : "Enter their code")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.cancelPairing() } } }
            }
        }
        #endif
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
