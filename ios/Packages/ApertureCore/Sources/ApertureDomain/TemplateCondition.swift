import Foundation

/// A condition in a tenant-authored template.
///
/// Deliberately a closed, tiny expression language rather than anything general. Templates
/// are authored by tenant administrators and evaluated on device, so the evaluator is a
/// surface that non-engineers write into. Keeping it to a fixed set of cases with no loops,
/// no function calls, and no host access means a template cannot hang the capture flow, and
/// cannot reach anything outside the form values it is handed.
///
/// The temptation to add "just one" escape hatch here should be resisted. A rule language
/// that can call out is a rule language that can be made to do anything.
public indirect enum TemplateCondition: Sendable, Equatable, Codable {
    case always
    case never
    case equals(field: String, value: FormValue)
    case notEquals(field: String, value: FormValue)
    case isPresent(field: String)
    case isAbsent(field: String)
    case greaterThan(field: String, value: Double)
    case lessThan(field: String, value: Double)
    case all([TemplateCondition])
    case any([TemplateCondition])
    case not(TemplateCondition)

    /// Nesting beyond this is rejected rather than evaluated.
    ///
    /// A template is data, and data arrives from a network. Bounded depth means a
    /// pathological or hostile template fails validation instead of consuming the stack
    /// while an inspector waits at a site.
    public static let maximumDepth = 8
}

public extension TemplateCondition {
    /// Evaluates against the current form values.
    ///
    /// Total: every case yields a value, and a reference to a field that does not exist is
    /// treated as absent rather than as an error. A template that names a field removed in
    /// a later version must not make an in-progress inspection unusable, and the inspector
    /// has no way to fix a template anyway.
    ///
    /// An over-deep condition is rejected **before** evaluation begins, as a whole. The
    /// obvious alternative, returning false from the recursion once a depth limit is hit,
    /// does not work: `not` inverts it, so the rejection flips with every enclosing
    /// negation and the answer depends on the parity of the nesting rather than on the
    /// rejection. Rejecting up front means nothing in the tree can invert it, because
    /// nothing in the tree runs.
    func evaluate(against values: [String: FormValue]) -> Bool {
        guard exceedsMaximumDepth() == false else { return false }
        return evaluateWithinDepth(against: values)
    }

    /// Whether nesting goes deeper than the limit.
    ///
    /// Bounded by construction: it descends at most `maximumDepth` frames, so asking the
    /// question about a hostile template is itself cheap. A check that has to walk the
    /// whole tree to discover the tree is too big has not helped.
    func exceedsMaximumDepth(_ remaining: Int = TemplateCondition.maximumDepth) -> Bool {
        guard remaining > 0 else { return true }

        switch self {
        case .all(let conditions), .any(let conditions):
            return conditions.contains { $0.exceedsMaximumDepth(remaining - 1) }
        case .not(let condition):
            return condition.exceedsMaximumDepth(remaining - 1)
        case .always, .never, .equals, .notEquals, .isPresent, .isAbsent,
             .greaterThan, .lessThan:
            return false
        }
    }

    private func evaluateWithinDepth(against values: [String: FormValue]) -> Bool {
        switch self {
        case .always:
            return true
        case .never:
            return false

        case .equals(let field, let expected):
            return values[field] == expected
        case .notEquals(let field, let expected):
            return values[field] != expected

        case .isPresent(let field):
            guard let value = values[field] else { return false }
            return value.isEmpty == false
        case .isAbsent(let field):
            guard let value = values[field] else { return true }
            return value.isEmpty

        case .greaterThan(let field, let threshold):
            guard case .number(let actual) = values[field] else { return false }
            return actual > threshold
        case .lessThan(let field, let threshold):
            guard case .number(let actual) = values[field] else { return false }
            return actual < threshold

        case .all(let conditions):
            return conditions.allSatisfy { $0.evaluateWithinDepth(against: values) }
        case .any(let conditions):
            return conditions.contains { $0.evaluateWithinDepth(against: values) }
        case .not(let condition):
            return condition.evaluateWithinDepth(against: values) == false
        }
    }

    /// Field keys this condition reads. Used to validate a template at publication time,
    /// so a rule naming a field that does not exist is caught by the author rather than by
    /// an inspector standing on a roof.
    ///
    /// Bounded like the others. It reports what it finds within the budget, which is
    /// sufficient because a condition deeper than the budget is rejected anyway.
    var referencedFields: Set<String> {
        referencedFields(within: TemplateCondition.maximumDepth + 1)
    }

    private func referencedFields(within budget: Int) -> Set<String> {
        guard budget > 0 else { return [] }

        switch self {
        case .always, .never:
            return []
        case .equals(let field, _), .notEquals(let field, _),
             .isPresent(let field), .isAbsent(let field),
             .greaterThan(let field, _), .lessThan(let field, _):
            return [field]
        case .all(let conditions), .any(let conditions):
            return conditions.reduce(into: Set<String>()) {
                $0.formUnion($1.referencedFields(within: budget - 1))
            }
        case .not(let condition):
            return condition.referencedFields(within: budget - 1)
        }
    }

    /// Nesting depth, saturating just past the limit.
    ///
    /// Saturating rather than exact, so computing it on a pathological template costs a
    /// bounded number of frames. The only question anyone asks of this value is whether it
    /// is over the limit, and a saturated answer settles that.
    var depth: Int {
        depth(within: TemplateCondition.maximumDepth + 2)
    }

    private func depth(within budget: Int) -> Int {
        guard budget > 0 else { return 0 }

        switch self {
        case .always, .never, .equals, .notEquals, .isPresent, .isAbsent,
             .greaterThan, .lessThan:
            return 1
        case .all(let conditions), .any(let conditions):
            return 1 + (conditions.map { $0.depth(within: budget - 1) }.max() ?? 0)
        case .not(let condition):
            return 1 + condition.depth(within: budget - 1)
        }
    }
}
