import ClipboardAnnotatorDomain
import Foundation
import XCTest
@testable import ClipboardAnnotator

@MainActor
final class ProfileSettingsTests: XCTestCase {
    func testMissingEmptyAndInvalidProfileDataFallBackToBuiltInsAndCoherent() throws {
        for seed in [Seed.missing, .empty, .invalidData] {
            let defaults = makeDefaults()
            defer { remove(defaults) }
            switch seed {
            case .missing:
                break
            case .empty:
                defaults.set(try JSONEncoder().encode([Profile]()), forKey: "profiles")
                defaults.set(UUID().uuidString, forKey: "activeProfileID")
            case .invalidData:
                defaults.set(Data("not json".utf8), forKey: "profiles")
                defaults.set(Profile.plain.id.uuidString, forKey: "activeProfileID")
            }

            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.profiles, Profile.builtIns)
            XCTAssertEqual(settings.activeProfileID, Profile.coherent.id)
            XCTAssertEqual(settings.activeProfile, .coherent)
            XCTAssertNotNil(defaults.data(forKey: "profiles"))
            XCTAssertEqual(defaults.string(forKey: "activeProfileID"), Profile.coherent.id.uuidString)
        }
    }

    func testUnknownActiveIDIsRepairedToFirstValidStoredProfile() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        defaults.set(try JSONEncoder().encode([Profile.pointByPoint, .plain]), forKey: "profiles")
        defaults.set(UUID().uuidString, forKey: "activeProfileID")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.profiles, [.pointByPoint, .plain])
        XCTAssertEqual(settings.activeProfileID, Profile.pointByPoint.id)
        XCTAssertEqual(defaults.string(forKey: "activeProfileID"), Profile.pointByPoint.id.uuidString)
    }

    func testMalformedProfileCollectionsFallBackAtomically() throws {
        var blank = Profile.plain
        blank.name = ""
        var untrimmed = Profile.plain
        untrimmed.name = " Plain "
        var foldedDuplicate = Profile.pointByPoint
        foldedDuplicate.name = "cOhÉrEnt"
        var duplicateID = Profile.pointByPoint
        duplicateID = Profile(
            id: Profile.coherent.id,
            name: duplicateID.name,
            preamble: duplicateID.preamble,
            includeApplication: duplicateID.includeApplication,
            includeWindow: duplicateID.includeWindow,
            includeLink: duplicateID.includeLink,
            includeTimestamps: duplicateID.includeTimestamps,
            includeHeading: duplicateID.includeHeading,
            clearSessionAfterExport: duplicateID.clearSessionAfterExport
        )
        let malformed: [[Profile]] = [
            [blank],
            [untrimmed],
            [.coherent, foldedDuplicate],
            [.coherent, duplicateID],
        ]

        for profiles in malformed {
            let defaults = makeDefaults()
            defer { remove(defaults) }
            defaults.set(try JSONEncoder().encode(profiles), forKey: "profiles")
            defaults.set(profiles[0].id.uuidString, forKey: "activeProfileID")

            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.profiles, Profile.builtIns)
            XCTAssertEqual(settings.activeProfileID, Profile.coherent.id)
        }
    }

    func testValidProfilesAndActiveProfilePersistAcrossSettingsInstances() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        var custom = Profile.plain
        custom = Profile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            name: "Custom",
            preamble: "Custom preamble",
            includeApplication: true,
            includeWindow: false,
            includeLink: true,
            includeTimestamps: false,
            includeHeading: true,
            clearSessionAfterExport: true
        )

        try settings.addProfile(custom)
        try settings.selectProfile(id: custom.id)
        let reloaded = AppSettings(defaults: defaults)

        XCTAssertEqual(reloaded.profiles, Profile.builtIns + [custom])
        XCTAssertEqual(reloaded.activeProfileID, custom.id)
        XCTAssertEqual(reloaded.activeProfile, custom)
    }

    func testSetupCompletionDefaultsFalseAndPersistsOnlyAfterExplicitCompletion() {
        let defaults = makeDefaults()
        defer { remove(defaults) }

        let initial = AppSettings(defaults: defaults)
        XCTAssertFalse(initial.hasCompletedSetup)
        XCTAssertNil(defaults.object(forKey: "hasCompletedSetup"))

        initial.completeSetup()
        initial.completeSetup()

        XCTAssertTrue(initial.hasCompletedSetup)
        XCTAssertEqual(defaults.object(forKey: "hasCompletedSetup") as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults).hasCompletedSetup)
    }

    func testInitializationRemovesObsoleteGlobalFormattingKeys() {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        defaults.set(true, forKey: "includeSource")
        defaults.set(false, forKey: "includeHeading")
        defaults.set(true, forKey: "clearAfterCopy")

        _ = AppSettings(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "includeSource"))
        XCTAssertNil(defaults.object(forKey: "includeHeading"))
        XCTAssertNil(defaults.object(forKey: "clearAfterCopy"))
    }

    func testDirtyExternalSelectionCancelKeepsDraftAndActiveProfile() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProfileEditorState(settings: settings)
        editor.draft.preamble = "Unsaved external draft"

        XCTAssertEqual(editor.requestSelection(Profile.plain.id), .needsDecision)
        XCTAssertFalse(try editor.resolvePendingSelection(.cancel))

        XCTAssertEqual(editor.editedProfileID, Profile.coherent.id)
        XCTAssertEqual(editor.draft.preamble, "Unsaved external draft")
        XCTAssertTrue(editor.isDirty)
        XCTAssertNil(editor.pendingProfileID)
        XCTAssertEqual(settings.activeProfileID, Profile.coherent.id)
    }

    func testCloseCancelAndFailedSaveKeepDraft() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProfileEditorState(settings: settings)
        editor.draft.name = Profile.pointByPoint.name

        XCTAssertFalse(try editor.resolveClose(.cancel))
        XCTAssertTrue(editor.isDirty)
        XCTAssertThrowsError(try editor.resolveClose(.save)) {
            XCTAssertEqual($0 as? ProfileMutationError, .duplicateName)
        }
        XCTAssertEqual(editor.draft.name, Profile.pointByPoint.name)
        XCTAssertEqual(settings.profile(id: Profile.coherent.id), .coherent)
    }

    func testCloseDiscardAndSaveDecisionsResolveDirtyDraft() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProfileEditorState(settings: settings)
        editor.draft.preamble = "Discard me"

        XCTAssertTrue(try editor.resolveClose(.discard))
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(editor.draft, .coherent)

        editor.draft.preamble = "Save me"
        XCTAssertTrue(try editor.resolveClose(.save))
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(settings.activeProfile.preamble, "Save me")
    }

    func testCloseSaveAsNewClonesDraftAndResolvesDirtyState() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000097")!
        let editor = ProfileEditorState(settings: settings, makeID: { newID })
        editor.draft.preamble = "Keep as a clone"

        XCTAssertTrue(try editor.resolveClose(.saveAsNew(name: "Close Clone")))

        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(editor.editedProfileID, newID)
        XCTAssertEqual(settings.activeProfileID, newID)
        XCTAssertEqual(settings.profile(id: Profile.coherent.id), .coherent)
        XCTAssertEqual(settings.profile(id: newID)?.preamble, "Keep as a clone")
    }

    func testDraftDoesNotAffectStoredProfileUntilSaveAndCanRevert() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProfileEditorState(settings: settings)
        editor.draft.preamble = "Changed"

        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(settings.activeProfile, .coherent)

        editor.revert()
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(editor.draft, .coherent)

        editor.draft.preamble = "Saved"
        try editor.save()
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(settings.activeProfile.preamble, "Saved")
    }

    func testDirtyDiscardSwitchPersistsPendingProfileAsActive() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProfileEditorState(settings: settings)
        editor.draft.preamble = "Unsaved"

        XCTAssertEqual(editor.requestSelection(Profile.pointByPoint.id), .needsDecision)
        XCTAssertEqual(settings.activeProfileID, Profile.coherent.id)
        editor.discardAndSelectPending()

        XCTAssertEqual(editor.editedProfileID, Profile.pointByPoint.id)
        XCTAssertEqual(editor.draft, .pointByPoint)
        XCTAssertEqual(settings.activeProfileID, Profile.pointByPoint.id)
        XCTAssertEqual(defaults.string(forKey: "activeProfileID"), Profile.pointByPoint.id.uuidString)
    }

    func testDirtySaveSwitchOverwritesSourceThenActivatesTarget() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProfileEditorState(settings: settings)
        editor.draft.name = "Renamed Coherent"

        XCTAssertEqual(editor.requestSelection(Profile.plain.id), .needsDecision)
        try editor.saveAndSelectPending()

        XCTAssertEqual(settings.profile(id: Profile.coherent.id)?.name, "Renamed Coherent")
        XCTAssertEqual(editor.editedProfileID, Profile.plain.id)
        XCTAssertEqual(settings.activeProfileID, Profile.plain.id)
    }

    func testSaveAsNewClonesDraftWithNewIDWithoutMutatingSource() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let editor = ProfileEditorState(settings: settings, makeID: { newID })
        editor.draft.preamble = "Clone only"

        let result = try editor.saveAsNew(named: "  My Profile  ")

        XCTAssertEqual(result, newID)
        XCTAssertEqual(settings.profile(id: Profile.coherent.id), .coherent)
        XCTAssertEqual(settings.profile(id: newID)?.name, "My Profile")
        XCTAssertEqual(settings.profile(id: newID)?.preamble, "Clone only")
        XCTAssertEqual(settings.activeProfileID, newID)
        XCTAssertEqual(editor.editedProfileID, newID)
    }

    func testDirtySaveAsNewSwitchClonesDraftThenPersistsPendingTargetAsActive() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000098")!
        let editor = ProfileEditorState(settings: settings, makeID: { newID })
        editor.draft.preamble = "Clone while switching"

        XCTAssertEqual(editor.requestSelection(Profile.plain.id), .needsDecision)
        try editor.saveAsNewAndSelectPending(named: "Switch Clone")

        XCTAssertEqual(settings.profile(id: Profile.coherent.id), Profile.coherent)
        XCTAssertEqual(settings.profile(id: newID)?.preamble, "Clone while switching")
        XCTAssertEqual(editor.editedProfileID, Profile.plain.id)
        XCTAssertEqual(settings.activeProfileID, Profile.plain.id)
        XCTAssertEqual(defaults.string(forKey: "activeProfileID"), Profile.plain.id.uuidString)
    }

    func testSaveAsNewRejectsBlankAndFoldedDuplicateNames() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProfileEditorState(settings: settings)
        editor.draft.preamble = "Dirty"

        XCTAssertThrowsError(try editor.saveAsNew(named: " \n ")) {
            XCTAssertEqual($0 as? ProfileMutationError, .emptyName)
        }
        XCTAssertThrowsError(try editor.saveAsNew(named: "cOhÉrEnt")) {
            XCTAssertEqual($0 as? ProfileMutationError, .duplicateName)
        }
        XCTAssertEqual(settings.profiles, Profile.builtIns)
        XCTAssertTrue(editor.isDirty)
    }

    func testDeleteIsGuardedWhileDirtyAndDeletingActiveKeepsValidActiveID() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        let editor = ProfileEditorState(settings: settings)
        editor.draft.preamble = "Dirty"
        XCTAssertThrowsError(try editor.delete()) {
            XCTAssertEqual($0 as? ProfileMutationError, .unsavedChanges)
        }

        editor.revert()
        try editor.delete()
        XCTAssertEqual(settings.profiles.count, 2)
        XCTAssertFalse(settings.profiles.contains(where: { $0.id == Profile.coherent.id }))
        XCTAssertEqual(settings.activeProfileID, Profile.pointByPoint.id)
        XCTAssertEqual(editor.editedProfileID, Profile.pointByPoint.id)

        try editor.delete()
        XCTAssertEqual(settings.profiles.count, 1)
        XCTAssertThrowsError(try editor.delete()) {
            XCTAssertEqual($0 as? ProfileMutationError, .lastProfile)
        }
        XCTAssertEqual(settings.activeProfileID, settings.profiles[0].id)
    }

    private enum Seed {
        case missing
        case empty
        case invalidData
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ProfileSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(suite, forKey: "testSuiteName")
        return defaults
    }

    private func remove(_ defaults: UserDefaults) {
        guard let suite = defaults.string(forKey: "testSuiteName") else { return }
        defaults.removePersistentDomain(forName: suite)
    }
}
