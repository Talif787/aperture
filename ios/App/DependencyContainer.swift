import Foundation
import Observation
import ApertureDomain
import ApertureTelemetry
import ApertureNetworking

/// The composition root.
///
/// Manual constructor injection, no framework. The graph is small enough to read in one
/// sitting, wiring errors are compile errors rather than runtime resolution failures,
/// there is no reflection, and nothing is added to the launch critical path where the
/// budget is 900 milliseconds to first interactive frame.
///
/// A dependency container framework earns its cost when a graph spans many teams and
/// hundreds of types. This one does not, and adopting one anyway would trade compile-time
/// safety for runtime failure modes in exchange for less typing.
@Observable
public final class DependencyContainer {
    /// Determinism seams. Production uses the system implementations; tests substitute
    /// controllable ones, which is what makes schedules and identifiers assertable.
    public let dateProvider: any DateProviding
    public let random: any RandomSource
    public let telemetry: any Telemetry
    public let environment: AppEnvironment

    public init(
        dateProvider: any DateProviding,
        random: any RandomSource,
        telemetry: any Telemetry,
        environment: AppEnvironment
    ) {
        self.dateProvider = dateProvider
        self.random = random
        self.telemetry = telemetry
        self.environment = environment
    }

    /// The production graph.
    ///
    /// Phase 1 wires the cross-cutting seams only. The local store, media store, sync
    /// engine, token manager, and inference actor are added in the phases that build them,
    /// each as a stored property here, so this file is also the inventory of what the
    /// application actually contains.
    public static func live(environment: AppEnvironment) -> DependencyContainer {
        DependencyContainer(
            dateProvider: SystemDateProvider(),
            random: SystemRandomSource(),
            telemetry: OSLogTelemetry(),
            environment: environment
        )
    }
}

/// Build-time configuration, read from the Info.plist values supplied by the xcconfig for
/// the active configuration.
///
/// There are no secrets here. The OAuth client identifier is public by design, and
/// everything else the app needs is fetched after authentication. A build configuration is
/// not a secret store, and treating it as one is how credentials reach a decompiled binary.
public struct AppEnvironment: Sendable, Equatable {
    public let name: String
    public let apiBaseURL: URL
    public let oauthClientID: String
    public let isDiagnosticsEnabled: Bool

    public init(name: String, apiBaseURL: URL, oauthClientID: String, isDiagnosticsEnabled: Bool) {
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.oauthClientID = oauthClientID
        self.isDiagnosticsEnabled = isDiagnosticsEnabled
    }

    /// Resolves from the bundle, failing loudly rather than falling back to a default.
    ///
    /// A silent fallback to a production URL in a debug build, or to a debug URL in a
    /// release build, is a class of mistake that is discovered by customers. A
    /// misconfigured build should not launch.
    public static var current: AppEnvironment {
        let bundle = Bundle.main

        guard
            let name = bundle.object(forInfoDictionaryKey: "ApertureEnvironmentName") as? String,
            let urlString = bundle.object(forInfoDictionaryKey: "ApertureAPIBaseURL") as? String,
            let url = URL(string: urlString),
            let clientID = bundle.object(forInfoDictionaryKey: "ApertureOAuthClientID") as? String
        else {
            fatalError(
                "Build configuration is incomplete. Check ios/Config/*.xcconfig and the "
                + "Info.plist key mappings for ApertureEnvironmentName, ApertureAPIBaseURL, "
                + "and ApertureOAuthClientID."
            )
        }

        let diagnostics = bundle.object(forInfoDictionaryKey: "ApertureDiagnosticsEnabled") as? Bool ?? false

        return AppEnvironment(
            name: name,
            apiBaseURL: url,
            oauthClientID: clientID,
            isDiagnosticsEnabled: diagnostics
        )
    }
}
