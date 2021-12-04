#if canImport(Darwin)
  import Darwin

  import SystemPackage

  struct SignalSet {

    // swift-format-ignore
    public static var all: Self {
      get throws {
        try Self(sigfillset)
      }
    }

    // swift-format-ignore
    public static var none: Self {
      get throws {
        try Self(sigemptyset)
      }
    }

    private init(_ fn: (UnsafeMutablePointer<sigset_t>) -> CInt) throws {
      rawValue = sigset_t()
      try Errno.check(fn(&rawValue))
    }
    var rawValue: sigset_t
  }

  enum PosixSpawn {

    public struct Flags: OptionSet {

      public static let closeFileDescriptorsByDefault = Flags(rawValue: POSIX_SPAWN_CLOEXEC_DEFAULT)

      public static let setSignalMask = Flags(rawValue: POSIX_SPAWN_SETSIGMASK)

      public init(rawValue: Int32) {
        self.rawValue = rawValue
      }
      public var rawValue: Int32
    }

    public struct Attributes: RawRepresentable {

      public init() throws {
        try Errno.check(posix_spawnattr_init(&rawValue))
      }

      public mutating func destroy() throws {
        try Errno.check(posix_spawnattr_destroy(&rawValue))
      }

      public mutating func setBlockedSignals(to signals: SignalSet) throws {
        try Errno.check(
          withUnsafePointer(to: signals.rawValue) { signals in
            posix_spawnattr_setsigmask(&rawValue, signals)
          })
      }

      public mutating func setFlags(_ flags: Flags) throws {
        try Errno.check(posix_spawnattr_setflags(&rawValue, Int16(flags.rawValue)))
      }

      public init(rawValue: posix_spawnattr_t?) {
        self.rawValue = rawValue
      }
      public var rawValue: posix_spawnattr_t?

    }

    public struct FileActions: RawRepresentable {

      public init() throws {
        try Errno.check(posix_spawn_file_actions_init(&rawValue))
      }

      public mutating func destroy() throws {
        try Errno.check(posix_spawn_file_actions_destroy(&rawValue))
      }

      public mutating func addChangeDirectory(to filePath: FilePath) throws {
        try Errno.check(
          filePath.withPlatformString {
            posix_spawn_file_actions_addchdir_np(&rawValue, $0)
          })
      }

      public mutating func addDuplicate(_ source: FileDescriptor, as target: CInt) throws {
        try Errno.check(posix_spawn_file_actions_adddup2(&rawValue, source.rawValue, target))
      }

      public init(rawValue: posix_spawn_file_actions_t?) {
        self.rawValue = rawValue
      }
      public var rawValue: posix_spawn_file_actions_t?

    }

    public static func spawn(
      _ path: FilePath,
      arguments: [String],
      environment: [String],
      fileActions: inout FileActions,
      attributes: inout Attributes
    ) throws -> pid_t {
      var pid = pid_t()

      let cArguments = arguments.map { $0.withCString(strdup)! }
      defer { cArguments.forEach { $0.deallocate() } }
      let cEnvironment = environment.map { $0.withCString(strdup)! }
      defer { cEnvironment.forEach { $0.deallocate() } }

      try path.withPlatformString { path in
        try Errno.check(
          posix_spawn(
            &pid,
            path,
            &fileActions.rawValue,
            &attributes.rawValue,
            cArguments + [nil],
            cEnvironment + [nil]))
      }

      return pid
    }

  }

  // MARK: - Support

  private extension Errno {
    static func check(_ value: CInt) throws {
      guard value == 0 else {
        throw Errno(rawValue: value)
      }
    }
  }

#endif
