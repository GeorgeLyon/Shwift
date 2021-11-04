
#if canImport(Darwin)
import Darwin

import SystemPackage

enum PosixSpawn {
  
  public struct Flags: OptionSet {
    
    public static let closeFileDescriptorsByDefault = Flags(rawValue: POSIX_SPAWN_CLOEXEC_DEFAULT)
    
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
      try Errno.check(filePath.withPlatformString {
        posix_spawn_file_actions_addchdir_np(&rawValue, $0)
      })
    }
    
    public mutating func addDuplicate(_ source: FileDescriptor, as target: FileDescriptor) throws {
      try Errno.check(posix_spawn_file_actions_adddup2(&rawValue, source.rawValue, target.rawValue))
    }
    
    public init(rawValue: posix_spawn_file_actions_t?) {
      self.rawValue = rawValue
    }
    public var rawValue: posix_spawn_file_actions_t?
    
  }
  
  public static func spawn<Environment: Sequence>(
    _ path: FilePath,
    arguments: [String],
    environment: Environment,
    fileActions: inout FileActions,
    attributes: inout Attributes
  ) throws -> pid_t
  where
    Environment.Element == (key: String, value: String)
  {
    var pid = pid_t()
    
    let cArguments = arguments.map { $0.withCString(strdup)! }
    defer { cArguments.forEach { $0.deallocate() } }
    let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)")! }
    defer { cEnvironment.forEach { $0.deallocate() } }
    
    try path.withPlatformString { path in
      try Errno.check(posix_spawn(
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
