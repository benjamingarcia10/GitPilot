import SwiftUI
import Sparkle
import Combine

// MARK: - Updater controller

/// Owns the Sparkle updater. Created once at app launch by `GitPilotApp`'s
/// `@StateObject`, which guarantees main-thread initialization (Sparkle uses
/// AppKit and `NSUserDefaults` from `init`, both of which require the main
/// thread). Constructing this off-main will crash.
@MainActor
final class UpdateController: ObservableObject {
    let updater: SPUUpdater
    private let controller: SPUStandardUpdaterController
    private let delegateProxy = UpdateDelegateProxy()

    @Published private(set) var canCheckForUpdates: Bool = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    @Published private(set) var lastCheckDate: Date?

    init() {
        // Pass the proxy as Sparkle's delegate so `didFinishUpdateCycleFor:`
        // can call back into us. We can't pass `self` here — `self` isn't
        // ready yet, and `UpdateController` is `@MainActor` while the proxy
        // method runs on whichever thread Sparkle invokes it from.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegateProxy,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.updater = controller.updater
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        self.lastCheckDate = controller.updater.lastUpdateCheckDate

        delegateProxy.owner = self

        // canCheckForUpdates IS documented as KVO-compliant on SPUUpdater.
        // lastUpdateCheckDate is NOT — the proxy refreshes it after each cycle.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// User-initiated check. Always shows UI (a "no updates available" alert
    /// even when current), which is what people expect from "Check for Updates…".
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Called by `UpdateDelegateProxy` on the main actor after each update
    /// cycle. Pulls the fresh `lastUpdateCheckDate` from Sparkle since the
    /// property isn't KVO-observable on its own.
    fileprivate func didFinishUpdateCycle() {
        lastCheckDate = updater.lastUpdateCheckDate
    }
}

// MARK: - Sparkle delegate proxy

/// Forwards Sparkle's `SPUUpdaterDelegate` callbacks to the main-actor
/// `UpdateController`. We use a separate object so `UpdateController` doesn't
/// have to inherit from `NSObject` and so the actor isolation boundary is
/// crossed cleanly via `Task { @MainActor in ... }`.
///
/// `nonisolated` on the delegate method is required because `SPUUpdaterDelegate`
/// is annotated `NS_SWIFT_UI_ACTOR` in Sparkle's headers, which would normally
/// pull conformers onto the main actor — but Sparkle's internal scheduler
/// invokes the callback from a private background thread. The body trampolines
/// back onto the main actor explicitly.
private final class UpdateDelegateProxy: NSObject, SPUUpdaterDelegate {
    /// Strong ref retained by `UpdateController`; the back-pointer is weak so
    /// the controller can deinit normally if ever released.
    weak var owner: UpdateController?

    /// The Obj-C selector is `updater:didFinishUpdateCycleForUpdateCheck:error:`
    /// but Swift's Obj-C importer applies SE-0005 type-suffix stripping —
    /// `…ForUpdateCheck:` with parameter type `SPUUpdateCheck` gets reduced to
    /// `…For:`, producing `updater(_:didFinishUpdateCycleFor:error:)`. The
    /// compiler enforces this: using the Obj-C-style name produces a
    /// "renamed to ..." error, so we can't accidentally typo our way into a
    /// never-firing optional method.
    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        // `owner` is a main-actor-isolated reference (UpdateController is
        // @MainActor), so we can't capture it in the Task's capture list from
        // this nonisolated context. Capture `self` (the proxy is plain NSObject)
        // and dereference owner inside the @MainActor body.
        Task { @MainActor [weak self] in
            self?.owner?.didFinishUpdateCycle()
        }
    }
}

// MARK: - Settings section

/// Rendered inside `SettingsView`. Surfaces version + manual check + auto-check
/// toggle. Sparkle's first-launch dialog still asks the user to opt in/out of
/// automatic checks; this is the long-term home for that preference.
struct UpdatesSettingsSection: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Version").foregroundStyle(.secondary)
                Spacer()
                Text(versionString).monospacedDigit()
            }

            Toggle("Check for updates automatically", isOn: $controller.automaticallyChecksForUpdates)

            HStack {
                if let last = controller.lastCheckDate {
                    Text("Last checked \(relativeString(last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never checked").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for Updates…") { controller.checkForUpdates() }
                    .disabled(!controller.canCheckForUpdates)
            }
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func relativeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: .now)
    }
}
