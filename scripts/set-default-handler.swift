// Set MDitor (dev.mditor.app) as the default handler
// for markdown document types. Run: swift scripts/set-default-handler.swift
import Foundation
import CoreServices

let bundleID: CFString = "dev.mditor.app" as NSString
let utis: [CFString] = [
    "net.daringfireball.markdown" as NSString,
    "public.markdown" as NSString,
]

for uti in utis {
    let err = LSSetDefaultRoleHandlerForContentType(uti, .editor, bundleID)
    if err == noErr {
        print("set default editor for \(uti)")
    } else {
        print("WARNING: LSSetDefaultRoleHandlerForContentType(\(uti)) failed: \(err)")
    }
}

for uti in utis {
    if let current = LSCopyDefaultRoleHandlerForContentType(uti, .editor)?.takeRetainedValue() {
        print("default editor for \(uti): \(current)")
    }
}
