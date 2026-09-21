import Foundation

/// Evaluates a template against the values entered so far.
///
/// Pure and synchronous. The capture flow calls this on every keystroke to decide what to
/// show, so it runs in the interaction path and must never touch disk, network, or a clock.
public struct TemplateEngine: Sendable {
    public init() {}

    /// Fields the inspector should currently see, in template order.
    public func visibleFields(
        in template: InspectionTemplate,
        values: [String: FormValue]
    ) -> [TemplateField] {
        template.fields.filter { $0.visibility.evaluate(against: values) }
    }

    /// Keys that must be answered before submission.
    ///
    /// **A hidden field is never required.** This is the rule that matters most in the whole
    /// engine, and it is enforced here rather than left to each caller. The alternative
    /// produces the worst class of form bug: submission blocked by a field the inspector
    /// cannot see, with no way to discover which one, and no way to fix it from a roof.
    public func requiredFieldKeys(
        in template: InspectionTemplate,
        values: [String: FormValue]
    ) -> Set<String> {
        Set(
            template.fields
                .filter { $0.visibility.evaluate(against: values) }
                .filter { $0.requirement.evaluate(against: values) }
                .map(\.key)
        )
    }

    /// Capture requirements currently in force, with how many assets are still outstanding.
    public func outstandingCaptures(
        in template: InspectionTemplate,
        values: [String: FormValue],
        capturedCounts: [String: Int]
    ) -> [(requirement: CaptureRequirement, outstanding: Int)] {
        template.captureRequirements
            .filter { $0.condition.evaluate(against: values) }
            .compactMap { requirement in
                let captured = capturedCounts[requirement.key] ?? 0
                let outstanding = requirement.minimumCount - captured
                return outstanding > 0 ? (requirement, outstanding) : nil
            }
    }

    /// Everything blocking submission, reported together.
    ///
    /// All of it at once, never one item at a time. A flow that surfaces the next problem
    /// only after the previous one is fixed sends an inspector back into an attic three
    /// separate times, and each trip costs more than the entire feature saved.
    public func completionGaps(
        in template: InspectionTemplate,
        values: [String: FormValue],
        capturedCounts: [String: Int] = [:]
    ) -> [FieldError] {
        var gaps: [FieldError] = []

        for key in requiredFieldKeys(in: template, values: values).sorted() {
            let value = values[key]
            if value == nil || value?.isEmpty == true {
                gaps.append(FieldError(fieldKey: key, reason: .required))
            }
        }

        for field in visibleFields(in: template, values: values) {
            guard let value = values[field.key] else { continue }
            if let error = validate(value, against: field) {
                gaps.append(error)
            }
        }

        for (requirement, _) in outstandingCaptures(
            in: template, values: values, capturedCounts: capturedCounts
        ) {
            gaps.append(FieldError(fieldKey: requirement.key, reason: .required))
        }

        return gaps
    }

    /// Checks one value against its field's declared constraints.
    public func validate(_ value: FormValue, against field: TemplateField) -> FieldError? {
        guard let validation = field.validation else { return typeMismatch(value, field) }

        switch value {
        case .number(let number):
            if let minimum = validation.minimum, number < minimum {
                return FieldError(
                    fieldKey: field.key,
                    reason: .outOfRange(minimum: validation.minimum, maximum: validation.maximum)
                )
            }
            if let maximum = validation.maximum, number > maximum {
                return FieldError(
                    fieldKey: field.key,
                    reason: .outOfRange(minimum: validation.minimum, maximum: validation.maximum)
                )
            }
        case .text(let text):
            if let limit = validation.maximumLength, text.count > limit {
                return FieldError(fieldKey: field.key, reason: .malformed)
            }
        case .boolean, .choice, .date:
            break
        }

        return typeMismatch(value, field)
    }

    /// A value whose shape does not match its field.
    ///
    /// Possible after a template migration: a field that was text becomes a choice, and a
    /// value entered under the previous version no longer fits. Reported rather than
    /// silently coerced, because a coerced measurement is a wrong measurement.
    private func typeMismatch(_ value: FormValue, _ field: TemplateField) -> FieldError? {
        let matches: Bool
        switch (value, field.kind) {
        case (.text, .text), (.number, .number), (.boolean, .boolean), (.date, .date):
            matches = true
        case (.choice(let selected), .choice(let options)):
            matches = options.contains(selected)
        default:
            matches = false
        }

        return matches ? nil : FieldError(fieldKey: field.key, reason: .unsupportedValue)
    }
}
