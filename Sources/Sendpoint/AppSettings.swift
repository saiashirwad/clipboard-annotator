import AppKit
import Carbon.HIToolbox
import SendpointDomain
import Observation
import ServiceManagement

enum ProfileMutationError: Error, Equatable, LocalizedError {
    case unknownProfile
    case lastProfile
    case emptyName
    case duplicateName
    case unsavedChanges

    var errorDescription: String? {
        switch self {
        case .unknownProfile:
            return "The profile no longer exists."
        case .lastProfile:
            return "The last profile cannot be deleted."
        case .emptyName:
            return "Enter a profile name."
        case .duplicateName:
            return "A profile with that name already exists."
        case .unsavedChanges:
            return "Save or discard the profile changes first."
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let profiles = "profiles"
        static let activeProfileID = "activeProfileID"
        static let captureCombo = "captureCombo"
        static let voiceCaptureCombo = "voiceCaptureCombo"
        static let copyCombo = "copyCombo"
        static let stackCombo = "stackCombo"
        static let switchSessionCombo = "switchSessionCombo"
        static let clearCombo = "clearCombo"
        static let pasteDirectly = "pasteDirectly"
        static let restoreFocusAfterSave = "restoreFocusAfterSave"
        static let hasCompletedSetup = "hasCompletedSetup"
    }

    private let defaults: UserDefaults

    var captureCombo: KeyCombo { didSet { persist(captureCombo, key: Key.captureCombo); onHotKeysChanged?() } }
    var voiceCaptureCombo: KeyCombo { didSet { persist(voiceCaptureCombo, key: Key.voiceCaptureCombo); onHotKeysChanged?() } }
    var copyCombo: KeyCombo { didSet { persist(copyCombo, key: Key.copyCombo); onHotKeysChanged?() } }
    var stackCombo: KeyCombo { didSet { persist(stackCombo, key: Key.stackCombo); onHotKeysChanged?() } }
    var switchSessionCombo: KeyCombo { didSet { persist(switchSessionCombo, key: Key.switchSessionCombo); onHotKeysChanged?() } }
    var clearCombo: KeyCombo { didSet { persist(clearCombo, key: Key.clearCombo); onHotKeysChanged?() } }

    private(set) var profiles: [Profile]
    private(set) var activeProfileID: UUID

    var activeProfile: Profile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
    }

    var pasteDirectly: Bool { didSet { defaults.set(pasteDirectly, forKey: Key.pasteDirectly); onHotKeysChanged?() } }
    var restoreFocusAfterSave: Bool { didSet { defaults.set(restoreFocusAfterSave, forKey: Key.restoreFocusAfterSave) } }
    private(set) var hasCompletedSetup: Bool

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Sendpoint: login item change failed — \(error)")
            }
        }
    }

    /// Called when a shortcut or direct-paste behavior changes.
    var onHotKeysChanged: (() -> Void)?
    /// Called after the active profile or stored profiles change.
    var onProfilesChanged: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        captureCombo = AppSettings.read(Key.captureCombo, from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .command])
        voiceCaptureCombo = AppSettings.read(Key.voiceCaptureCombo, from: defaults)
            ?? .optionSpace
        copyCombo = AppSettings.read(Key.copyCombo, from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_ANSI_V), modifiers: [.control, .command])
        stackCombo = AppSettings.read(Key.stackCombo, from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifiers: [.control, .command])
        switchSessionCombo = AppSettings.read(Key.switchSessionCombo, from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .command])
        clearCombo = AppSettings.read(Key.clearCombo, from: defaults)
            ?? KeyCombo(keyCode: UInt16(kVK_Delete), modifiers: [.control, .command])

        let decoded = defaults.data(forKey: Key.profiles)
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) }
        let loadedProfiles = AppSettings.validProfiles(decoded)
        let loadedStoredProfiles = decoded.map { !$0.isEmpty && loadedProfiles == $0 } ?? false
        profiles = loadedProfiles

        let requestedID = loadedStoredProfiles
            ? defaults.string(forKey: Key.activeProfileID).flatMap(UUID.init(uuidString:))
            : nil
        activeProfileID = requestedID.flatMap { requested in
            loadedProfiles.contains(where: { $0.id == requested }) ? requested : nil
        } ?? loadedProfiles[0].id

        pasteDirectly = defaults.object(forKey: Key.pasteDirectly) as? Bool ?? true
        restoreFocusAfterSave = defaults.object(forKey: Key.restoreFocusAfterSave) as? Bool ?? true
        hasCompletedSetup = defaults.object(forKey: Key.hasCompletedSetup) as? Bool ?? false
        launchAtLogin = SMAppService.mainApp.status == .enabled

        for obsoleteKey in ["includeSource", "includeHeading", "clearAfterCopy"] {
            defaults.removeObject(forKey: obsoleteKey)
        }
        persistProfiles()
        persistActiveProfileID()
    }

    func completeSetup() {
        guard !hasCompletedSetup else { return }
        hasCompletedSetup = true
        defaults.set(true, forKey: Key.hasCompletedSetup)
    }

    func selectProfile(id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else {
            throw ProfileMutationError.unknownProfile
        }
        guard activeProfileID != id else { return }
        activeProfileID = id
        persistActiveProfileID()
        onProfilesChanged?()
    }

    func updateProfile(_ profile: Profile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ProfileMutationError.unknownProfile
        }
        var stored = profile
        stored.name = try validatedName(profile.name, excluding: profile.id)
        guard stored != profiles[index] else { return }
        profiles[index] = stored
        persistProfiles()
        onProfilesChanged?()
    }

    func addProfile(_ profile: Profile) throws {
        guard !profiles.contains(where: { $0.id == profile.id }) else {
            throw ProfileMutationError.duplicateName
        }
        var stored = profile
        stored.name = try validatedName(profile.name, excluding: nil)
        profiles.append(stored)
        persistProfiles()
        onProfilesChanged?()
    }

    @discardableResult
    func deleteProfile(id: UUID) throws -> UUID {
        guard profiles.count > 1 else { throw ProfileMutationError.lastProfile }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileMutationError.unknownProfile
        }
        profiles.remove(at: index)
        if activeProfileID == id {
            activeProfileID = profiles[min(index, profiles.count - 1)].id
            persistActiveProfileID()
        }
        persistProfiles()
        onProfilesChanged?()
        return activeProfileID
    }

    func profile(id: UUID) -> Profile? {
        profiles.first(where: { $0.id == id })
    }

    func validatedName(_ proposedName: String, excluding profileID: UUID?) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileMutationError.emptyName }
        let normalized = Self.normalizedProfileName(trimmed)
        guard !profiles.contains(where: {
            $0.id != profileID && Self.normalizedProfileName($0.name) == normalized
        }) else { throw ProfileMutationError.duplicateName }
        return trimmed
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Key.profiles)
    }

    private func persistActiveProfileID() {
        defaults.set(activeProfileID.uuidString, forKey: Key.activeProfileID)
    }

    private func persist(_ combo: KeyCombo, key: String) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private static func validProfiles(_ decoded: [Profile]?) -> [Profile] {
        guard let decoded, !decoded.isEmpty else { return Profile.builtIns }
        var ids: Set<UUID> = []
        var names: Set<String> = []
        for profile in decoded {
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmed.isEmpty,
                trimmed == profile.name,
                ids.insert(profile.id).inserted,
                names.insert(normalizedProfileName(profile.name)).inserted
            else { return Profile.builtIns }
        }
        return decoded
    }

    private static func normalizedProfileName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}
