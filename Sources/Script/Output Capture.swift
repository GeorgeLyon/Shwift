
public func outputOf(_ operation: @escaping () async throws -> Void) async throws -> String {
  let lines = try await Shell.PipableCommand(operation) | reduce(into: []) { $0.append($1) }
  return lines.joined(separator: "\n")
}
