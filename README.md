# Shwift

Shwift is a package which provides tools for shell scripting in Swift. 

Some of the capability is demonstrated in `ScriptExample`:
https://github.com/GeorgeLyon/Shwift/blob/5bd293e8f7723bd5815a17fc78fc85c67c03e85f/Sources/ScriptExample/Main.swift#L7-L32

## Shell

The core of Shwift is a library called `Shell`. This implements the basic functionality of creating shells and subshells, launching executables, writing builtins (executable-like operations that execute in-process) and piping between executions.
Shell is built on top of `swift-nio` and is entirely non-blocking 

## Script

Script adds a user-friendly API on top of `Shell` and tightly integrates with `swift-argument-parser` to writing bash-like scripts in Swift.

