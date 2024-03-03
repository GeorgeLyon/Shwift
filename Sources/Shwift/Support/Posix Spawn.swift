#if canImport(Darwin)
  import Darwin
#elseif canImport(CLinuxSupport) && canImport(Glibc)
  import Glibc
  import CLinuxSupport
#else
  #error("Unsupported Platform")
#endif

import SystemPackage

struct SignalSet {

  static var all: Self {
    get throws {
      try Self(sigfillset)
    }
  }

  static var none: Self {
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

  struct Flags: OptionSet {

    #if canImport(Darwin)
      static let closeFileDescriptorsByDefault = Flags(rawValue: POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif

    static let setSignalMask = Flags(rawValue: POSIX_SPAWN_SETSIGMASK)

    init(rawValue: Int32) {
      self.rawValue = rawValue
    }
    var rawValue: Int32
  }

  struct Attributes {

    init() throws {
      try Errno.check(posix_spawnattr_init(&rawValue))
    }

    mutating func destroy() throws {
      try Errno.check(posix_spawnattr_destroy(&rawValue))
    }

    mutating func setBlockedSignals(to signals: SignalSet) throws {
      try Errno.check(
        withUnsafePointer(to: signals.rawValue) { signals in
          posix_spawnattr_setsigmask(&rawValue, signals)
        })
    }

    mutating func setFlags(_ flags: Flags) throws {
      try Errno.check(posix_spawnattr_setflags(&rawValue, Int16(flags.rawValue)))
    }

    var rawValue: posix_spawnattr_t = .init()
  }

  struct FileActions {

    init() throws {
      try Errno.check(posix_spawn_file_actions_init(&rawValue))
    }

    mutating func destroy() throws {
      try Errno.check(posix_spawn_file_actions_destroy(&rawValue))
    }

    mutating func addChangeDirectory(to filePath: FilePath) throws {
      try Errno.check(
        filePath.withPlatformString {
          Shwift_posix_spawn_file_actions_addchdir_np(&rawValue, $0)
        })
    }

    mutating func addCloseFileDescriptors(from lowestFileDescriptorValueToClose: Int32) throws {
      try Errno.check(
        Shwift_posix_spawn_file_actions_addclosefrom_np(&rawValue, lowestFileDescriptorValueToClose)
      )
    }

    mutating func addCloseFileDescriptor(_ value: Int32) throws {
      try Errno.check(
        posix_spawn_file_actions_addclose(&rawValue, value)
      )
    }

    mutating func addDuplicate(_ source: FileDescriptor, as target: CInt) throws {
      try Errno.check(posix_spawn_file_actions_adddup2(&rawValue, source.rawValue, target))
    }

    var rawValue: posix_spawn_file_actions_t = .init()
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
