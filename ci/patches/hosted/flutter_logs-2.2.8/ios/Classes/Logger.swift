//
//  File.swift
//  Squares
//
//  Created by Matthias Hochgatterer on 03/12/14.
//  Copyright (c) 2014 Matthias Hochgatterer. All rights reserved.
//
//  Fushi patch (BUG-5067), see ci/patches/hosted/flutter_logs-2.2.8/PATCHES.md:
//  upstream appended with the legacy FileHandle.seekToEndOfFile() / write(_:)
//  API. Those report I/O failures (ENOSPC when the device storage is full,
//  EIO, ...) by raising an Objective-C NSFileHandleOperationException, which
//  Swift cannot catch, so a full disk aborted the whole app (SIGABRT on the
//  "File output" queue). Appending now goes through the throwing
//  seekToEnd() / write(contentsOf:) / close() API (iOS 13.4+; every pod is
//  built for iOS 15.1 by fushi/ios/Podfile), and a failed open yields nil.
//
import Foundation
import Dispatch
import Swift

public protocol Output {
    func process(_ string: String)
}

public struct ConsoleOutput: Output {
    private var queue: DispatchQueue

    public init() {
        self.queue = DispatchQueue(label: "Console output")
    }

    public func process(_ string: String) {
        queue.sync {
            Swift.print(string)
        }
    }
}

/// Opens `path` for appending, creating the file first if needed.
///
/// Returns nil when the file cannot be created or opened (for example the
/// volume is full or the directory is gone), so the caller drops the entry.
fileprivate func openForAppending(atPath path: String) -> FileHandle? {
    if !FileManager.default.fileExists(atPath: path) {
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: nil) else {
            return nil
        }
    }
    return FileHandle(forWritingAtPath: path)
}

/// Appends one line to `file` with the throwing FileHandle API.
///
/// A log line that cannot be written is dropped: the logger is the only
/// channel that could report its own failure, and the failure it would
/// report is the very condition that prevents writing. On failure the handle
/// is released when this function returns; FileHandle(forWritingAtPath:)
/// owns its descriptor and closes it on deallocation, so nothing leaks.
fileprivate func appendLine(_ string: String, to file: FileHandle) {
    guard let data = (string + "\n").data(using: String.Encoding.utf8) else {
        return
    }
    do {
        try file.seekToEnd()
        try file.write(contentsOf: data)
        try file.close()
    } catch {
        // Drop this entry (see above); never let a disk error kill the app.
    }
}

public class FileOutput: Output {
    var filePath: String
    private var queue: DispatchQueue

    public init(filePath: String) {
        self.filePath = filePath
        self.queue = DispatchQueue(label: "File output")
    }

    public func process(_ string: String) {
        queue.sync(execute: {
            [weak self] in
            if let file = self?.getFileHandle() {
                appendLine(string, to: file)
            }
        })
    }


    private func getFileHandle() -> FileHandle? {
        return openForAppending(atPath: filePath)
    }
}

public class URLOutput: Output {
    var url: URL
    private var queue: DispatchQueue

    public init(url: URL) {
        self.url = url
        self.queue = DispatchQueue(label: "URL output")
    }

    public func process(_ string: String) {
        queue.sync(execute: {
            [weak self] in
            if let file = self?.getFileHandle() {
                appendLine(string, to: file)
            }
        })
    }


    private func getFileHandle() -> FileHandle? {
        return openForAppending(atPath: url.absoluteString)
    }
}

private let _sharedInstance = Logger()
public class Logger {
    public class var sharedInstance: Logger {
        return _sharedInstance
    }
    private var outputs: [Output]

    public init() {
        outputs = [Output]()
        outputs.append(ConsoleOutput())
    }

    public func addOutput(_ output: Output) {
        if (!outputs.contains(where: {type(of: $0) == type(of: output)})) {
        outputs.append(output)
        }
    }

    public func log(_ string: String) {
        for out in outputs {
            out.process(string)
        }
    }
}
