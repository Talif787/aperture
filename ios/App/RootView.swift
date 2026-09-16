import SwiftUI
import ApertureDesignSystem
import FeatureInspection

/// The root scene.
///
/// Phase 1 renders a build-verification surface rather than product UI: it proves the
/// module graph links, the design system resolves, the environment configuration loaded,
/// and the app launches on device. Feature navigation replaces this in Phase 4, when
/// there are features to navigate to.
///
/// It is deliberately not a placeholder screen with filler text. It shows the four facts
/// an engineer needs when a build misbehaves, which is genuinely useful during bring-up
/// and during the first TestFlight round.
struct RootView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            List {
                Section("Build") {
                    LabeledContent("Environment", value: container.environment.name)
                    LabeledContent("API", value: container.environment.apiBaseURL.absoluteString)
                    LabeledContent("Version", value: Self.versionString)
                    LabeledContent("Diagnostics", value: container.environment.isDiagnosticsEnabled ? "on" : "off")
                }

                Section("Sync") {
                    SyncPostureRow(posture: .upToDate)
                }
            }
            .navigationTitle("Aperture")
            .font(Tokens.Typography.body)
        }
    }

    private static var versionString: String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(short) (\(build))"
    }
}

/// The persistent sync indicator, present from Phase 1 because it is referenced by the
/// non-blocking-offline requirement and it is easier to keep it correct than to retrofit
/// it once every screen has its own idea of what "pending" looks like.
struct SyncPostureRow: View {
    let posture: SyncPosture

    var body: some View {
        LabeledContent("Status") {
            Text(label)
                .foregroundStyle(posture.demandsUserAction ? Tokens.Color.warning : Tokens.Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Synchronization status"))
        .accessibilityValue(Text(label))
    }

    private var label: String {
        switch posture {
        case .upToDate:
            return String(localized: "Up to date", comment: "Sync status when nothing is queued")
        case .offline(let pending):
            return String(
                localized: "\(pending) waiting to sync",
                comment: "Sync status while offline, with the count of queued operations"
            )
        case .syncing(let remaining):
            return String(
                localized: "Syncing, \(remaining) left",
                comment: "Sync status while draining the queue"
            )
        case .attentionRequired(let stuck):
            return String(
                localized: "\(stuck) need attention",
                comment: "Sync status when operations are dead-lettered and require the user"
            )
        }
    }
}
