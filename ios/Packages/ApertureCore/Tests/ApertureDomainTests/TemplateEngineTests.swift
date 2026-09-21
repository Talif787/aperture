import Testing
import Foundation
@testable import ApertureDomain
import ApertureTestSupport

@Suite("Template engine")
struct TemplateEngineTests {

    private let engine = TemplateEngine()

    private func template() -> InspectionTemplate {
        TemplateFixtures.roofInspection(
            id: TemplateID(rawValue: UUID()),
            version: 1
        )
    }

    @Test("a conditional field is hidden until its condition holds")
    func conditionalVisibility() {
        let template = template()

        let shingle: [String: FormValue] = ["roof_material": .choice("asphalt_shingle")]
        let other: [String: FormValue] = ["roof_material": .choice("other")]

        let shingleKeys = engine.visibleFields(in: template, values: shingle).map(\.key)
        let otherKeys = engine.visibleFields(in: template, values: other).map(\.key)

        #expect(shingleKeys.contains("roof_material_other") == false)
        #expect(otherKeys.contains("roof_material_other"))
    }

    @Test("a hidden field is never required")
    func hiddenFieldsAreNotRequired() {
        let template = template()

        // Slope is 12 degrees, so the fall-protection question is not shown.
        let values: [String: FormValue] = [
            "roof_material": .choice("metal"),
            "slope_degrees": .number(12)
        ]

        let required = engine.requiredFieldKeys(in: template, values: values)

        // The rule that matters most in the engine. A field that is required but invisible
        // blocks submission with no way for the inspector to discover which one, and no way
        // to fix it from a roof.
        #expect(required.contains("fall_protection_used") == false)
        #expect(required.contains("roof_material_other") == false)
        #expect(required == ["roof_material", "slope_degrees"])
    }

    @Test("a field becomes required once its condition holds")
    func conditionalRequirement() {
        let template = template()

        let steep: [String: FormValue] = [
            "roof_material": .choice("tile"),
            "slope_degrees": .number(45)
        ]

        #expect(engine.requiredFieldKeys(in: template, values: steep).contains("fall_protection_used"))
    }

    @Test("every gap is reported at once, not one at a time")
    func allGapsTogether() {
        let template = template()

        let gaps = engine.completionGaps(in: template, values: [:], capturedCounts: [:])
        let keys = Set(gaps.map(\.fieldKey))

        // Two unanswered required fields plus the unconditional capture requirement. A flow
        // that surfaces the next problem only after the last is fixed sends an inspector
        // back into an attic three separate times.
        #expect(keys.contains("roof_material"))
        #expect(keys.contains("slope_degrees"))
        #expect(keys.contains("elevation_photos"))
    }

    @Test("a conditional capture requirement applies only when its condition holds")
    func conditionalCaptureRequirement() {
        let template = template()

        let metal: [String: FormValue] = ["roof_material": .choice("metal"), "slope_degrees": .number(10)]
        let shingle: [String: FormValue] = ["roof_material": .choice("asphalt_shingle"), "slope_degrees": .number(10)]

        let metalKeys = engine.outstandingCaptures(in: template, values: metal, capturedCounts: [:])
            .map(\.requirement.key)
        let shingleKeys = engine.outstandingCaptures(in: template, values: shingle, capturedCounts: [:])
            .map(\.requirement.key)

        #expect(metalKeys.contains("damage_closeups") == false)
        #expect(shingleKeys.contains("damage_closeups"))
    }

    @Test("outstanding counts decrease as assets are captured")
    func outstandingCounts() {
        let template = template()
        let values: [String: FormValue] = ["roof_material": .choice("metal"), "slope_degrees": .number(10)]

        let partial = engine.outstandingCaptures(
            in: template, values: values, capturedCounts: ["elevation_photos": 3]
        )
        let complete = engine.outstandingCaptures(
            in: template, values: values, capturedCounts: ["elevation_photos": 4]
        )

        #expect(partial.first?.outstanding == 1)
        #expect(complete.isEmpty)
    }

    @Test("a value outside its declared range is a gap")
    func rangeValidation() {
        let template = template()
        let values: [String: FormValue] = [
            "roof_material": .choice("metal"),
            "slope_degrees": .number(120)
        ]

        let gaps = engine.completionGaps(in: template, values: values)

        #expect(gaps.contains { $0.fieldKey == "slope_degrees" })
    }

    @Test("a value whose shape no longer matches its field is reported, not coerced")
    func typeMismatchAfterMigration() {
        let template = template()
        // A value entered when the field was free text, now that it is a choice. Possible
        // after a template migration.
        let values: [String: FormValue] = [
            "roof_material": .text("asphalt_shingle"),
            "slope_degrees": .number(10)
        ]

        let gaps = engine.completionGaps(in: template, values: values)

        // Coercing would produce a plausible-looking value nobody entered. In a document
        // that settles a claim, a quietly corrected field is worse than a rejected one.
        #expect(gaps.contains { $0.fieldKey == "roof_material" && $0.reason == .unsupportedValue })
    }

    @Test("a complete form has no gaps")
    func completeForm() {
        let template = template()
        let values: [String: FormValue] = [
            "roof_material": .choice("metal"),
            "slope_degrees": .number(22),
            "access_notes": .text("Ladder set at the north elevation.")
        ]

        let gaps = engine.completionGaps(
            in: template,
            values: values,
            capturedCounts: ["elevation_photos": 4]
        )

        #expect(gaps.isEmpty, "unexpected gaps: \(gaps.map(\.fieldKey))")
    }
}

@Suite("Template conditions")
struct TemplateConditionTests {

    @Test("a reference to a missing field is absent, not an error")
    func missingFieldIsAbsent() {
        // A template naming a field removed in a later version must not make an in-progress
        // inspection unusable. The inspector cannot edit templates.
        #expect(TemplateCondition.isPresent(field: "gone").evaluate(against: [:]) == false)
        #expect(TemplateCondition.isAbsent(field: "gone").evaluate(against: [:]))
        #expect(TemplateCondition.equals(field: "gone", value: .boolean(true)).evaluate(against: [:]) == false)
    }

    @Test("an empty string counts as absent, a false boolean does not")
    func emptinessSemantics() {
        #expect(TemplateCondition.isPresent(field: "a").evaluate(against: ["a": .text("  ")]) == false)
        // "Is the meter accessible" answered no is a complete answer, not a blank.
        #expect(TemplateCondition.isPresent(field: "b").evaluate(against: ["b": .boolean(false)]))
    }

    @Test("all and any compose")
    func composition() {
        let values: [String: FormValue] = ["x": .number(10), "y": .boolean(true)]

        let both = TemplateCondition.all([
            .greaterThan(field: "x", value: 5),
            .equals(field: "y", value: .boolean(true))
        ])
        let either = TemplateCondition.any([
            .greaterThan(field: "x", value: 50),
            .equals(field: "y", value: .boolean(true))
        ])
        let neither = TemplateCondition.all([
            .greaterThan(field: "x", value: 50),
            .equals(field: "y", value: .boolean(false))
        ])

        #expect(both.evaluate(against: values))
        #expect(either.evaluate(against: values))
        #expect(neither.evaluate(against: values) == false)
    }

    @Test(
        "excessive nesting is rejected regardless of the parity of the negations",
        arguments: [9, 10, 39, 40, 41]
    )
    func depthIsBounded(negations: Int) {
        var condition = TemplateCondition.always
        for _ in 0..<negations {
            condition = .not(condition)
        }

        // Parameterized over both odd and even counts on purpose. Rejecting by returning
        // false from inside the recursion looks correct until `not` inverts it: the
        // rejection then flips with every enclosing negation, and the answer depends on the
        // parity of the nesting rather than on the depth. Rejecting the condition as a whole
        // before evaluating it means nothing in the tree can invert the decision.
        #expect(condition.exceedsMaximumDepth())
        #expect(condition.evaluate(against: [:]) == false)
    }

    @Test("nesting within the limit still evaluates normally", arguments: [0, 1, 2, 7])
    func shallowNestingIsUnaffected(negations: Int) {
        var condition = TemplateCondition.always
        for _ in 0..<negations {
            condition = .not(condition)
        }

        #expect(condition.exceedsMaximumDepth() == false)
        #expect(condition.evaluate(against: [:]) == (negations % 2 == 0))
    }

    @Test("referenced fields are discoverable for authoring-time validation")
    func referencedFields() {
        let condition = TemplateCondition.all([
            .equals(field: "a", value: .boolean(true)),
            .any([.isPresent(field: "b"), .greaterThan(field: "c", value: 1)])
        ])

        #expect(condition.referencedFields == ["a", "b", "c"])
    }

    @Test("a template naming an unknown field fails validation at authoring time")
    func templateValidation() {
        let template = InspectionTemplate(
            id: TemplateID(rawValue: UUID()),
            version: 1,
            name: "Broken",
            fields: [
                TemplateField(key: "a", label: "A", kind: .boolean),
                TemplateField(key: "a", label: "Duplicate", kind: .boolean),
                TemplateField(
                    key: "b", label: "B", kind: .boolean,
                    visibility: .isPresent(field: "does_not_exist")
                ),
                TemplateField(key: "c", label: "C", kind: .choice([]))
            ]
        )

        let problems = template.validationProblems()

        #expect(problems.contains { $0.contains("duplicate field key 'a'") })
        #expect(problems.contains { $0.contains("unknown field 'does_not_exist'") })
        #expect(problems.contains { $0.contains("choice with no options") })
    }
}
