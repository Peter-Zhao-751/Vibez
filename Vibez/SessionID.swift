//
//  SessionID.swift
//  Vibez
//
//  Centralizes the "is this session id usable?" check the push/shield
//  code makes in many places: a session id counts only when it's
//  non-empty and not the "nosid" sentinel the plugins send for
//  untagged events.
//

import Foundation

extension String {
    /// True when this session id is non-empty and not the `"nosid"`
    /// sentinel (the value the plugins send when an event has no session).
    var isUsableSessionId: Bool {
        !isEmpty && self != "nosid"
    }
}
