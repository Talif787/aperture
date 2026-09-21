import Foundation

/// A versioned, immutable inspection template.
///
/// Published versions are never mutated. An inspection pins the version it started with, so
/// a template republished mid-shift cannot change the form under an inspector who is
/// halfway through it, and a finding recorded last week remains interpretable against the
/// rules that produced it.
public struct InspectionTemplate: Sendable, Equatable, Identifiable, Codable {
    public let id: TemplateID
    public let version: Int
    public let name: String
    public let fields: [TemplateField]
    public let captureRequirements: [CaptureRequirement]

    public init(
        id: TemplateID,
        version: Int,
        name: String,
        fields: [TemplateField],
        captureRequirements: [CaptureRequirement] = []
    ) {
        precondition(version > 0, "a published template version starts at one")
        self.id = id
        self.version = version
        self.name = name
        self.fields = fields
        self.captureRequirements = captureRequirements
    }

    public func field(forKey key: String) -> TemplateField? {
        fields.first { $0.key == key }
    }

    /// Problems that make a template unfit to publish.
    ///
    /// Run at authoring time, not at capture time. A rule that names a field which does not
    /// exist is a mistake the author can fix in a browser; discovering it on a roof is not
    /// a recoverable situation for the inspector, who cannot edit templates at all.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        let keys = Set(fields.map(\.key))

        let duplicates = Dictionary(grouping: fields, by: \.key).filter { $0.value.count > 1 }
        for key in duplicates.keys.sorted() {
            problems.append("duplicate field key '\(key)'")
        }

        for field in fields {
            for referenced in field.visibility.referencedFields.union(field.requirement.referencedFields)
            where keys.contains(referenced) == false {
                problems.append("field '\(field.key)' references unknown field '\(referenced)'")
            }
            if field.visibility.exceedsMaximumDepth() || field.requirement.exceedsMaximumDepth() {
                problems.append(
                    "field '\(field.key)' nests deeper than \(TemplateCondition.maximumDepth)"
                )
            }
            if case .choice(let options) = field.kind, options.isEmpty {
                problems.append("field '\(field.key)' is a choice with no options")
            }
        }

        return problems.sorted()
    }
}

/// One field in a template.
public struct TemplateField: Sendable, Equatable, Codable {
    /// Stable key, used for storage, dirty tracking, and the wire format. Distinct from the
    /// label, which is localized and may change without consequence.
    public let key: String
    public let label: String
    public let kind: Kind

    /// When this field appears. A hidden field is never required, which the engine enforces
    /// rather than leaving to each caller.
    public let visibility: TemplateCondition
    public let requirement: TemplateCondition
    public let validation: Validation?

    public enum Kind: Sendable, Equatable, Codable {
        case text(multiline: Bool)
        case number(unit: String?)
        case boolean
        case choice([String])
        case date
    }

    public struct Validation: Sendable, Equatable, Codable {
        public let minimum: Double?
        public let maximum: Double?
        public let maximumLength: Int?

        public init(minimum: Double? = nil, maximum: Double? = nil, maximumLength: Int? = nil) {
            self.minimum = minimum
            self.maximum = maximum
            self.maximumLength = maximumLength
        }
    }

    public init(
        key: String,
        label: String,
        kind: Kind,
        visibility: TemplateCondition = .always,
        requirement: TemplateCondition = .never,
        validation: Validation? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.visibility = visibility
        self.requirement = requirement
        self.validation = validation
    }
}

/// Evidence a template demands, as opposed to data it collects.
public struct CaptureRequirement: Sendable, Equatable, Codable {
    public let key: String
    public let label: String
    public let kind: MediaAsset.Kind
    public let minimumCount: Int
    public let condition: TemplateCondition

    public init(
        key: String,
        label: String,
        kind: MediaAsset.Kind,
        minimumCount: Int = 1,
        condition: TemplateCondition = .always
    ) {
        precondition(minimumCount > 0, "a capture requirement asks for at least one asset")
        self.key = key
        self.label = label
        self.kind = kind
        self.minimumCount = minimumCount
        self.condition = condition
    }
}
