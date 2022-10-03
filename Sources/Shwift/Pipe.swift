import SystemPackage

extension Builtin {

  /**
   Creates two file descriptors which are valid for the duration of `source` and `destination`, respectively. Data written to `source` will be readable from `destination` just like a unix pipe.
   */
  public static func pipe<SourceOutcome, DestinationOutcome>(
    _ source: (FileDescriptor) async throws -> SourceOutcome,
    to destination: (FileDescriptor) async throws -> DestinationOutcome
  ) async throws -> (source: SourceOutcome, destination: DestinationOutcome) {
    let pipe = try FileDescriptor.pipe()

    async let sourceOutcome: SourceOutcome = {
      defer { try! pipe.writeEnd.close() }
      return try await source(pipe.writeEnd)
    }()

    async let destinationOutcome: DestinationOutcome = {
      defer { try! pipe.readEnd.close() }
      return try await destination(pipe.readEnd)
    }()

    let sourceResult: Result<SourceOutcome, Error>
    do {
      sourceResult = .success(try await sourceOutcome)
    } catch {
      sourceResult = .failure(error)
    }

    let destinationResult: Result<DestinationOutcome, Error>
    do {
      destinationResult = .success(try await destinationOutcome)
    } catch {
      destinationResult = .failure(error)
    }

    /// We use  results to ensure we wait on both tasks even if one throws
    return (try sourceResult.get(), try destinationResult.get())
  }

}
