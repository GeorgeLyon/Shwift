# Shwift

Shwift is a package which provides tools for shell scripting in Swift. 



## Shell

The core of Shwift is a library called `Shell`. This implements the basic functionality of creating shells and subshells, launching executables, writing builtins (executable-like operations that execute in-process) and piping between executions.
Shell is built on top of `swift-nio` and is entirely non-blocking 

## Script

Script adds a user-friendly API on top of `Shell` and tightly integrates with `swift-argument-parser` to writing bash-like scripts in Swift.

