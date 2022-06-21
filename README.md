# Shwift

## Overview

Shwift is a package which provides tools for shell scripting in Swift. 

For example, you can write:
```
try await echo("Foo", "Bar") | sed("s/Bar/Baz/")
```

More capability is demonstrated in the [`ScriptExample` target](https://github.com/GeorgeLyon/Shwift/blob/552b32eacbf02a20ae51cae316e47ec4223a2005/Sources/ScriptExample/Main.swift#L29).

The `Shwift` library provides some basic building blocks for launching executables and processing their output using builtins. It is built to be non-blocking (thanks to `swift-nio`), which works really well with the new Swift concurrency features. 

The `Script` library brings these capabilities together with `swift-argument-parser` for providing a familiar and user-friendly API for writing shell scripts in Swift. For instance, while `Shwift` provides the basic capability of piping the output of one command to another, `Script` provides the `|` operator to do this the way you would in a shell script.
