// Posts a command to a running debug build's drive hook (Sources/ArgentApp/Automation.swift): a
// distributed notification named BUNDLE-ID.drive whose object is the command. The hook replies in
// the unified log, subsystem camera.argent.Argent, category drive, where lib.zsh reads it.
//
//     argent-drive camera.argent.Argent.m3mem develop-measure /path/out tiff16 timeline
//
// build-measure-app.sh compiles it beside the measuring app.
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: argent-drive BUNDLE-ID COMMAND...\n".utf8))
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(arguments[0] + ".drive"), object: arguments.dropFirst().joined(separator: " "),
    userInfo: nil, deliverImmediately: true)
