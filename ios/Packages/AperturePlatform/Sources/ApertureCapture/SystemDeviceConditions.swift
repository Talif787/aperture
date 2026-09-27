import ApertureDomain
import Foundation

/// Reports the device's thermal and power state.
///
/// A thin adapter over ProcessInfo, and thin on purpose. The interesting decisions about
/// what to do under heat live in the domain, where they can be tested without warming a
/// phone up; this type only translates Apple's vocabulary into the domain's.
public struct SystemDeviceConditions: DeviceConditionProviding {
    private let processInfo: ProcessInfo

    public init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    public var thermalState: ThermalState {
        switch processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            // A state Apple adds later is treated as the worst known one.
            //
            // The alternative, mapping it to nominal, means a future OS could report a
            // thermal condition this build has never heard of and the app would respond by
            // running inference at full resolution into it.
            return .critical
        }
    }

    public var isLowPowerModeEnabled: Bool {
        processInfo.isLowPowerModeEnabled
    }
}

/// Publishes thermal and power changes as they happen.
///
/// Separate from the reader because they are used differently: capture asks for the current
/// state before each acquisition, while the interface wants to know the moment it changes so
/// it can tell the inspector before they notice the app has slowed down.
@MainActor
@Observable
public final class DeviceConditionMonitor {
    public private(set) var thermalState: ThermalState
    public private(set) var isLowPowerModeEnabled: Bool

    private let conditions: SystemDeviceConditions
    private var observers: [NSObjectProtocol] = []

    public init(conditions: SystemDeviceConditions = SystemDeviceConditions()) {
        self.conditions = conditions
        self.thermalState = conditions.thermalState
        self.isLowPowerModeEnabled = conditions.isLowPowerModeEnabled
    }

    public func start() {
        guard observers.isEmpty else { return }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.thermalState = self.conditions.thermalState
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLowPowerModeEnabled = self.conditions.isLowPowerModeEnabled
                }
            }
        )
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit {
        // Not calling stop() here: deinit is nonisolated and stop() is main-actor bound.
        // Removing the observers directly is equivalent and does not require hopping.
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
