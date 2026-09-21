import Foundation
import ApertureDomain
import ApertureSync
import ApertureTestSupport

/// A development tool for exercising domain policy by hand.
///
/// Not shipped in the application. It exists because the template engine, the storage
/// policy, and the thermal policy all make decisions that are easy to describe and hard to
/// believe without seeing: which fields appear, which become required, what still blocks
/// submission. A test asserts one case; this lets you ask arbitrary ones.
///
///     swift run ApertureScenarios template '{"roof_material":"other"}'
///     swift run ApertureScenarios storage 400MB
///     swift run ApertureScenarios thermal serious

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first else {
    printUsage()
    exit(1)
}

switch command {
case "template":
    runTemplate(json: arguments.count > 1 ? arguments[1] : "{}",
                capturedCounts: arguments.count > 2 ? arguments[2] : "{}")
case "storage":
    runStorage(argument: arguments.count > 1 ? arguments[1] : "0")
case "thermal":
    runThermal(argument: arguments.count > 1 ? arguments[1] : "nominal")
case "fields":
    printTemplateDefinition()
case "policy":
    printConflictPolicy()
case "conflict":
    runConflict(
        local: arguments.count > 1 ? arguments[1] : "",
        remote: arguments.count > 2 ? arguments[2] : "",
        localClock: arguments.count > 3 ? UInt64(arguments[3]) ?? 2000 : 2000,
        remoteClock: arguments.count > 4 ? UInt64(arguments[4]) ?? 1000 : 1000
    )
case "merge":
    runMerge(first: arguments.count > 1 ? arguments[1] : "",
             second: arguments.count > 2 ? arguments[2] : "")
case "converge":
    await runConverge(
        seed: arguments.count > 1 ? UInt64(arguments[1]) ?? 1 : 1,
        steps: arguments.count > 2 ? Int(arguments[2]) ?? 60 : 60
    )
default:
    printUsage()
    exit(1)
}

// MARK: - Commands

func runTemplate(json: String, capturedCounts: String) {
    let template = TemplateFixtures.roofInspection(id: TemplateID(rawValue: UUID()))
    let engine = TemplateEngine()

    let values = parseValues(json, template: template)
    let counts = parseCounts(capturedCounts)

    print("Input values")
    if values.isEmpty {
        print("  (none)")
    } else {
        for key in values.keys.sorted() {
            print("  \(key) = \(describe(values[key]))")
        }
    }

    print("\nVisible fields")
    for field in engine.visibleFields(in: template, values: values) {
        print("  \(field.key)  (\(describeKind(field.kind)))")
    }

    let required = engine.requiredFieldKeys(in: template, values: values)
    print("\nRequired now")
    print(required.isEmpty ? "  (none)" : required.sorted().map { "  \($0)" }.joined(separator: "\n"))

    let outstanding = engine.outstandingCaptures(
        in: template, values: values, capturedCounts: counts
    )
    print("\nOutstanding captures")
    if outstanding.isEmpty {
        print("  (none)")
    } else {
        for entry in outstanding {
            print("  \(entry.requirement.key)  needs \(entry.outstanding) more")
        }
    }

    let gaps = engine.completionGaps(in: template, values: values, capturedCounts: counts)
    print("\nBlocking submission")
    if gaps.isEmpty {
        print("  nothing: this inspection can be submitted")
    } else {
        for gap in gaps {
            print("  \(gap.fieldKey)  \(describe(gap.reason))")
        }
    }
}

func runStorage(argument: String) {
    let bytes = parseBytes(argument)
    let disposition = StoragePolicy.disposition(availableBytes: bytes)

    print("Available: \(format(bytes: bytes))")
    print("Warning threshold: \(format(bytes: StoragePolicy.warningThreshold))")
    print("Blocking threshold: \(format(bytes: StoragePolicy.blockingThreshold))")
    print("\nDisposition: \(disposition)")

    switch disposition {
    case .ample:
        print("  Capture proceeds normally.")
    case .warning:
        print("  Capture proceeds. Confirmed-synced media becomes eligible for eviction.")
    case .blocked:
        let needed = StoragePolicy.blockingThreshold - bytes
        print("  Capture is refused BEFORE acquisition, needing \(format(bytes: needed)) more.")
        print("  Refusing after the shutter fires would be the one unacceptable outcome:")
        print("  the inspector saw it fire and will believe the evidence exists.")
    }
}

func runThermal(argument: String) {
    guard let state = ThermalState(rawValue: argument) else {
        print("Unknown thermal state '\(argument)'.")
        print("Expected one of: \(ThermalState.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(1)
    }

    print("Thermal state: \(state.rawValue)")
    print("  capture:            always permitted")
    print("  inference:          \(state.permitsInference ? "permitted" : "deferred")")
    print("  reduced resolution: \(state.requiresReducedResolution ? "yes" : "no")")
    print("")
    print("Capture never stops for heat. Losing the evidence is worse than losing the")
    print("analysis: the analysis can be redone from the media, the site cannot be revisited.")
}

func printTemplateDefinition() {
    let template = TemplateFixtures.roofInspection(id: TemplateID(rawValue: UUID()))

    print("Template: \(template.name)  (version \(template.version))\n")
    print("Fields")
    for field in template.fields {
        print("  \(field.key)")
        print("    kind:       \(describeKind(field.kind))")
        print("    visible:    \(describe(field.visibility))")
        print("    required:   \(describe(field.requirement))")
    }

    print("\nCapture requirements")
    for requirement in template.captureRequirements {
        print("  \(requirement.key)  \(requirement.minimumCount) x \(requirement.kind.rawValue)")
        print("    when: \(describe(requirement.condition))")
    }

    let problems = template.validationProblems()
    print("\nAuthoring validation: \(problems.isEmpty ? "no problems" : problems.joined(separator: "; "))")
}

// MARK: - Parsing

/// A JSON scalar, decoded without going through `NSNumber`.
///
/// `JSONSerialization` returns booleans and numbers as the same bridged type, and telling
/// them apart requires CoreFoundation calls that do not exist in swift-corelibs-foundation.
/// Decoding into a closed enum avoids the question entirely and behaves identically on
/// Linux and on Apple platforms, which is the property this whole package depends on.
enum JSONScalar: Decodable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Bool first. A JSON `true` also satisfies nothing else, but a number asked to
        // decode as Bool throws, so the order is what keeps `1` a number.
        if let flag = try? container.decode(Bool.self) {
            self = .boolean(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected a string, number, or boolean"
            )
        }
    }
}

/// Coerces JSON into form values using the template to decide the intended shape.
///
/// A JSON string is ambiguous on its own: it could be free text or a choice. Consulting the
/// field's declared kind removes the guess, which is the same thing the real form layer does.
func parseValues(_ json: String, template: InspectionTemplate) -> [String: FormValue] {
    guard let data = json.data(using: .utf8) else {
        print("Could not read the values argument. Received: \(json)")
        exit(1)
    }

    let scalars: [String: JSONScalar]
    do {
        scalars = try JSONDecoder().decode([String: JSONScalar].self, from: data)
    } catch {
        print("Could not parse the values argument as a JSON object of scalars.")
        print("Received: \(json)")
        print("Detail: \(error)")
        exit(1)
    }

    var values: [String: FormValue] = [:]

    for (key, scalar) in scalars {
        let kind = template.field(forKey: key)?.kind

        switch scalar {
        case .string(let text):
            if case .choice = kind {
                values[key] = .choice(text)
            } else {
                values[key] = .text(text)
            }
        case .number(let number):
            if case .boolean = kind {
                values[key] = .boolean(number != 0)
            } else {
                values[key] = .number(number)
            }
        case .boolean(let flag):
            values[key] = .boolean(flag)
        }
    }

    return values
}

func parseCounts(_ json: String) -> [String: Int] {
    guard let data = json.data(using: .utf8),
          let counts = try? JSONDecoder().decode([String: Int].self, from: data) else {
        return [:]
    }
    return counts
}

func parseBytes(_ argument: String) -> Int64 {
    let upper = argument.uppercased()
    let multipliers: [(String, Int64)] = [
        ("GB", 1024 * 1024 * 1024), ("MB", 1024 * 1024), ("KB", 1024), ("B", 1)
    ]

    for (suffix, multiplier) in multipliers where upper.hasSuffix(suffix) {
        let number = upper.replacingOccurrences(of: suffix, with: "")
        return Int64(Double(number) ?? 0) * multiplier
    }

    return Int64(argument) ?? 0
}

// MARK: - Formatting

func describe(_ value: FormValue?) -> String {
    switch value {
    case .text(let text): return "text(\"\(text)\")"
    case .number(let number): return "number(\(number))"
    case .boolean(let flag): return "boolean(\(flag))"
    case .choice(let choice): return "choice(\"\(choice)\")"
    case .date(let date): return "date(\(date))"
    case nil: return "absent"
    }
}

func describeKind(_ kind: TemplateField.Kind) -> String {
    switch kind {
    case .text(let multiline): return multiline ? "multiline text" : "text"
    case .number(let unit): return unit.map { "number in \($0)" } ?? "number"
    case .boolean: return "boolean"
    case .choice(let options): return "choice of \(options.joined(separator: ", "))"
    case .date: return "date"
    }
}

func describe(_ condition: TemplateCondition) -> String {
    switch condition {
    case .always: return "always"
    case .never: return "never"
    case .equals(let field, let value): return "\(field) == \(describe(value))"
    case .notEquals(let field, let value): return "\(field) != \(describe(value))"
    case .isPresent(let field): return "\(field) is answered"
    case .isAbsent(let field): return "\(field) is unanswered"
    case .greaterThan(let field, let value): return "\(field) > \(value)"
    case .lessThan(let field, let value): return "\(field) < \(value)"
    case .all(let conditions): return "all(" + conditions.map(describe).joined(separator: ", ") + ")"
    case .any(let conditions): return "any(" + conditions.map(describe).joined(separator: ", ") + ")"
    case .not(let condition): return "not(" + describe(condition) + ")"
    }
}

func describe(_ reason: FieldError.Reason) -> String {
    switch reason {
    case .required: return "is required and unanswered"
    case .outOfRange(let minimum, let maximum):
        // A closure rather than `String.init`: passing the initializer unapplied is
        // ambiguous across six overloads, and the compiler cannot pick one from context.
        let low = minimum.map { "\($0)" } ?? "any"
        let high = maximum.map { "\($0)" } ?? "any"
        return "is outside \(low) to \(high)"
    case .malformed: return "is malformed"
    case .unsupportedValue: return "has a value that does not fit this field"
    }
}

func format(bytes: Int64) -> String {
    let gigabyte = 1024.0 * 1024 * 1024
    let megabyte = 1024.0 * 1024
    if Double(bytes) >= gigabyte { return String(format: "%.2f GB", Double(bytes) / gigabyte) }
    return String(format: "%.0f MB", Double(bytes) / megabyte)
}

func printUsage() {
    print("""
    Aperture domain scenarios, a development tool.

      template '<json values>' ['<json capture counts>']
          What the engine decides for a set of answers.

      storage <bytes|400MB|2GB>
          Whether capture is permitted at that free-space level.

      thermal <nominal|fair|serious|critical>
          What degrades, and what never does.

      fields
          The fixture template, with every condition spelled out.

      policy
          The per-field conflict policy table.

      conflict <local,fields> <remote,fields> [localClockMs] [remoteClockMs]
          What resolution decides for a concurrent change.

      merge '<inspector text>' '<reviewer text>'
          Note merging, with the algebraic properties checked.

      converge <seed> [steps]
          A generated history of edits, failures and terminations, replayed.

    Examples
      swift run ApertureScenarios fields
      swift run ApertureScenarios template '{"roof_material":"other"}'
      swift run ApertureScenarios template '{"roof_material":"asphalt_shingle","slope_degrees":45}'
      swift run ApertureScenarios storage 400MB
      swift run ApertureScenarios conflict measurement_value measurement_value
      swift run ApertureScenarios converge 42 80
    """)
}
