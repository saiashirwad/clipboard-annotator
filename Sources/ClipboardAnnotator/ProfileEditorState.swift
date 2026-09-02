import ClipboardAnnotatorDomain
import Foundation
import Observation

@MainActor
@Observable
final class ProfileEditorState {
    enum SelectionResult: Equatable {
        case selected
        case unchanged
        case needsDecision
        case rejected
    }

    enum DirtyDecision: Equatable {
        case save
        case saveAsNew(name: String)
        case discard
        case cancel
    }

    private let settings: AppSettings
    private let makeID: () -> UUID

    private(set) var editedProfileID: UUID
    var draft: Profile
    private(set) var pendingProfileID: UUID?

    init(settings: AppSettings, makeID: @escaping () -> UUID = UUID.init) {
        self.settings = settings
        self.makeID = makeID
        let profile = settings.activeProfile
        editedProfileID = profile.id
        draft = profile
    }

    var storedProfile: Profile? { settings.profile(id: editedProfileID) }
    var isDirty: Bool { storedProfile != draft }
    var canDelete: Bool { settings.profiles.count > 1 }
    var profiles: [Profile] { settings.profiles }

    @discardableResult
    func requestSelection(_ id: UUID) -> SelectionResult {
        guard settings.profile(id: id) != nil else { return .rejected }
        guard id != editedProfileID else { return .unchanged }
        guard isDirty else {
            selectImmediately(id)
            return .selected
        }
        pendingProfileID = id
        return .needsDecision
    }

    func validatedNewProfileName(_ name: String) throws -> String {
        try settings.validatedName(name, excluding: nil)
    }

    func save() throws {
        try settings.updateProfile(draft)
        draft = settings.profile(id: editedProfileID) ?? draft
    }

    @discardableResult
    func saveAsNew(named name: String) throws -> UUID {
        var clone = draft
        clone = Profile(
            id: makeID(),
            name: name,
            preamble: clone.preamble,
            includeApplication: clone.includeApplication,
            includeWindow: clone.includeWindow,
            includeLink: clone.includeLink,
            includeTimestamps: clone.includeTimestamps,
            includeHeading: clone.includeHeading,
            clearSessionAfterExport: clone.clearSessionAfterExport
        )
        try settings.addProfile(clone)
        selectImmediately(clone.id)
        return clone.id
    }

    func revert() {
        guard let storedProfile else { return }
        draft = storedProfile
        pendingProfileID = nil
    }

    func delete() throws {
        guard !isDirty else { throw ProfileMutationError.unsavedChanges }
        let oldProfiles = settings.profiles
        guard let oldIndex = oldProfiles.firstIndex(where: { $0.id == editedProfileID }) else {
            throw ProfileMutationError.unknownProfile
        }
        let deletedID = editedProfileID
        _ = try settings.deleteProfile(id: deletedID)
        let nextIndex = min(oldIndex, settings.profiles.count - 1)
        selectImmediately(settings.profiles[nextIndex].id)
    }

    func saveAndSelectPending() throws {
        guard let pendingProfileID else { return }
        try save()
        selectImmediately(pendingProfileID)
    }

    func saveAsNewAndSelectPending(named name: String) throws {
        guard let destination = pendingProfileID else { return }
        _ = try saveAsNew(named: name)
        selectImmediately(destination)
    }

    func discardAndSelectPending() {
        guard let pendingProfileID else { return }
        selectImmediately(pendingProfileID)
    }

    func cancelPendingSelection() {
        pendingProfileID = nil
    }

    @discardableResult
    func resolvePendingSelection(_ decision: DirtyDecision) throws -> Bool {
        guard pendingProfileID != nil else { return true }
        switch decision {
        case .save:
            try saveAndSelectPending()
        case let .saveAsNew(name):
            try saveAsNewAndSelectPending(named: name)
        case .discard:
            discardAndSelectPending()
        case .cancel:
            cancelPendingSelection()
            return false
        }
        return true
    }

    @discardableResult
    func resolveClose(_ decision: DirtyDecision) throws -> Bool {
        guard isDirty else { return true }
        switch decision {
        case .save:
            try save()
        case let .saveAsNew(name):
            _ = try saveAsNew(named: name)
        case .discard:
            revert()
        case .cancel:
            return false
        }
        return true
    }

    func synchronize() {
        guard settings.profile(id: editedProfileID) == nil else { return }
        selectImmediately(settings.activeProfile.id)
    }

    private func selectImmediately(_ id: UUID) {
        guard let profile = settings.profile(id: id) else { return }
        try? settings.selectProfile(id: id)
        editedProfileID = id
        draft = profile
        pendingProfileID = nil
    }
}
