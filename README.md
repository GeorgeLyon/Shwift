# Shwift

## Overview

Shwift is a package which provides tools for shell scripting in Swift. 

For example, you can write the following swift code to achieve `echo Foo Bar | sed s/Bar/Baz/`:
```swift
try await echo("Foo", "Bar") | sed("s/Bar/Baz/")
```

While a bit more verbose, this is natively integrated into Swift and utilizes Swift's concurrency APIs. As a result, interacting with command-line tools becomes very natural, and you can do things like `echo("Foo", "Bar") | map { $0.replacingOccurences(of: "Bar", with: "Baz" }`. We've worked very hard to make the performance of `Shwift` analogous with the command line. So if you execute the line `try await cat("/dev/urandom") | xxd() | head -n2`, You won't read any more from `/dev/urandom` than if you executed the analogous command in the terminal.

The `Script` module provides API that is as similar as possible to the terminal, but expressed in Swift. It leverages `swift-argument-parser` and is potimized for writing shell-script-like programs. Here is an example of a simple program you can write (a more detailed example can be found in the [`ScriptExample` target](https://github.com/GeorgeLyon/Shwift/blob/552b32eacbf02a20ae51cae316e47ec4223a2005/Sources/ScriptExample/Main.swift#L29)):

```swift 
import Script

@main struct Main: Script {

  func run() async throws {
    /**
     Declare the executables first so that we fail fast if one is missing.

     We could also instead use the `execute("executable", ...)` form to resolve executables at invocation time.
     */
    let echo = try await executable(named: "echo")

    try await echo("Foo", "Bar") | map { $0.replacingOccurrences(of: "Bar", with: "Baz") }
  }
  
}
```

`Script` is implemented using the `Shwift` module, which implements the core functionality needed to call command-line tools and process their output. This module can be used directly if you want to interact with command-line tools in a more complex program. For example, you could implement a server which may call a command-line tool in response to an HTTP request.

`Shwift` is more explicit about exactly what is being executed. You have a `Shwift.Context` which you can use to manage the lifetime of resources used by `Shwift` (for example, closing the `Shwift.Context` once it is no longer necessary). It also provides `Builtin`, which is a namespace for core functionality that is used to implement higher level Swift functions for interacting with command line tools in `Script`, like `map` and `reduce`.

`Shwift` is build on top of `swift-nio` and as a result aims to be completely non-blocking, and thus suitable for use Swift programs which make extensive use of Swift's concurrency features, such as servers.

`Shwift` also provides its own `Process` type. This type has a different API from `Foundation.Process` and embraces Swift's concurrency features, which the `Foundation.Process` API predates. It also works around a [nasty Foundation bug on Linux](https://github.com/apple/swift-corelibs-foundation/issues/3946) which can result in leaked file descriptors or deadlocks in concurrently-executing code. 
