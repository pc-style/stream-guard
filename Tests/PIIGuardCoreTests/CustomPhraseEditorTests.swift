import Testing
@testable import PIIGuardCore

@Test func duplicateAddIsCaseAndDiacriticInsensitive() {
    #expect(CustomPhraseEditor.update(["Café"], with: " CAFE ", editing: nil) == .duplicate)
}

@Test func duplicateEditDoesNotReplaceExistingPhrase() {
    #expect(
        CustomPhraseEditor.update(["Nightjar", "Café"], with: "NIGHTJAR", editing: 1) == .duplicate
    )
}

@Test func validEditChangesOnlySelectedPhrase() {
    #expect(
        CustomPhraseEditor.update(["Nightjar", "Café"], with: "  Skylark  ", editing: 1)
            == .changed(["Nightjar", "Skylark"])
    )
}

@Test func unchangedEditDoesNotReportASettingsChange() {
    #expect(CustomPhraseEditor.update(["Nightjar"], with: "Nightjar", editing: 0) == .unchanged)
}
