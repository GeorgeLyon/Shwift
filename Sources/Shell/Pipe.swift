
extension Shell {
  
  public func pipe<T>(
    _ source: @Sendable (Shell) async throws -> Void,
    to destination: @Sendable (Shell) async throws -> T
  ) async throws -> T {
    let sourceShell = subshell()
    async let sourceResult: Void = try await source(sourceShell)
    let destinationShell = subshell()
    async let destinationResult = try await destination(destinationShell)
    try await sourceResult
    return try await destinationResult
  }
  
}
