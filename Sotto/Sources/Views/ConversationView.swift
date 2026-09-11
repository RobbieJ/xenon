import SwiftUI
import SottoCore

struct ConversationView: View {
    @Environment(SessionCoordinator.self) private var session
    @State private var traceURL: URL?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle()
                    .fill(session.partnerIsTalking ? Color.green.opacity(0.25) : Color.secondary.opacity(0.1))
                    .frame(width: 180, height: 180)
                    .animation(.easeInOut(duration: 0.15), value: session.partnerIsTalking)
                Text(String(session.state.partner?.displayName.prefix(1) ?? "?"))
                    .font(.system(size: 64, weight: .semibold))
            }
            Text(session.state.partner?.displayName ?? "")
                .font(.title3)
            Text(session.partnerIsTalking ? "Talking" : "Listening")
                .foregroundStyle(.secondary)

            LevelBar(levelDBFS: session.localLevelDBFS)
                .frame(height: 8)
                .padding(.horizontal, 40)

            HStack(spacing: 24) {
                stat("Latency", session.linkQuality.estimatedLatencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "–")
                stat("Buffer", "\(session.jitterStatistics.targetMilliseconds) ms")
                stat("Concealed", "\(session.jitterStatistics.concealed)")
            }
            .font(.footnote.monospacedDigit())

            if !session.routeSummary.isEmpty {
                Text(session.routeSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            // Phase 0 measurement export. Stays in the developer builds only (see UX-SPEC §4, Settings).
            if let traceURL {
                ShareLink(item: traceURL) {
                    Label("Share measurement CSV", systemImage: "square.and.arrow.up")
                }
                .font(.footnote)
            } else {
                Button("Prepare measurement CSV") { traceURL = session.exportTrace() }
                    .font(.footnote)
            }
            Spacer()
            HStack(spacing: 40) {
                Button {
                    session.toggleMute()
                } label: {
                    Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.title)
                        .frame(width: 72, height: 72)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .tint(session.isMuted ? .orange : .accentColor)

                Button(role: .destructive) {
                    session.end()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title)
                        .frame(width: 72, height: 72)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
            }
            .padding(.bottom, 24)
        }
        .padding()
        .alert("New phone connected", isPresented: Binding(get: { session.unknownPartnerName != nil }, set: { if !$0 { session.unknownPartnerName = nil } })) {
            Button("Keep talking") { session.unknownPartnerName = nil }
            Button("End", role: .destructive) { session.unknownPartnerName = nil; session.end() }
        } message: {
            Text("\(session.unknownPartnerName ?? "A phone") is not one of your remembered partners.")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.body.monospacedDigit())
            Text(title).foregroundStyle(.secondary)
        }
    }
}

struct LevelBar: View {
    let levelDBFS: Double
    var body: some View {
        GeometryReader { geo in
            let fraction = max(0, min(1, (levelDBFS + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * fraction)
            }
        }
    }
}
