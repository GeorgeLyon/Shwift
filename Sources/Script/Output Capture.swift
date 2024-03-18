import Shwift

/**
 Captures operation output as text.

 By default, input is processed per line (delimited by newline),
 and the result String contains each output line separated by newlines (but without an terminating newline).

 - Parameters:
 - delimiter: Character to split input into segments (defaults to newline)
   - separator: String used to join output items into a single String (defaults to newlin)
   - operation: closure writing to output stream to capture
 - Throws: rethrows errors thrown by underlying operations
 - Returns: String of output items delimited by separator
 */
public func outputOf(
  segmentingInputAt delimiter: Character = Builtin.Input.Lines.eol,
  withOutputSeparator separator: String = Builtin.Input.Lines.eolStr,
  _ operation: @escaping () async throws -> Void
) async throws -> String {
  let lines =
    try await Shell.PipableCommand(operation)
    | reduce(into: [], segmentingInputAt: delimiter) { $0.append($1) }
  return lines.joined(separator: separator)
}
