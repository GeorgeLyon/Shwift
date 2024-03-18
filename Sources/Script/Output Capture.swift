public func outputOf(
  segmentingInputAt delimiter: Character = "\n",
  withOutputSeparator separator: String = "\n",
  _ operation: @escaping () async throws -> Void
) async throws -> String {
  let lines = try await Shell.PipableCommand(operation) 
    | reduce(into: [], segmentingInputAt: delimiter) { $0.append($1) }
  return lines.joined(separator: separator)
}
