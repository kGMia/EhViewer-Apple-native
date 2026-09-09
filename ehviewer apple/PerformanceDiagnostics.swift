//
//  PerformanceDiagnostics.swift
//  ehviewer apple
//
//  Lightweight native signposts for Instruments. No user data is persisted
//  or uploaded; interval names are static and contain no gallery metadata.
//

import Foundation
import os

@MainActor
enum PerformanceDiagnostics {
    private static let logger = Logger(
        subsystem: "Stellatrix.ehviewer-apple",
        category: "Performance"
    )
    private static let signposter = OSSignposter(logger: logger)

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState

        func end() {
            PerformanceDiagnostics.signposter.endInterval(name, state)
        }
    }

    static func begin(_ name: StaticString) -> Interval {
        let id = signposter.makeSignpostID()
        return Interval(
            name: name,
            state: signposter.beginInterval(name, id: id)
        )
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}

/// Launch-only controls for cold-start A/B captures. No production preference
/// or menu behavior changes unless a DEBUG launch explicitly selects a probe.
enum GalleryPreviewDiagnostics {
    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments
    static let omitShareLink = arguments.contains("-EHPreviewWithoutShare")
    static let useSystemSnapshot = arguments.contains("-EHPreviewSystemSnapshot")
    static let useStaticTitle = arguments.contains("-EHPreviewStaticTitle")
    static let skipInteractionWarmup = arguments.contains("-EHSkipInteractionWarmup")
    #else
    static let omitShareLink = false
    static let useSystemSnapshot = false
    static let useStaticTitle = false
    static let skipInteractionWarmup = false
    #endif
}
