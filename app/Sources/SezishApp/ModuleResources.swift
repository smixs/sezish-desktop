import Foundation

// SwiftPM's generated Bundle.module only checks the .app root and the dev .build
// path, but `make bundle` ships resource bundles in Contents/Resources — look
// there first or resource lookup fails on any machine but the dev's.
let moduleResources: Bundle =
    Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("sezish_SezishApp.bundle")) }
    ?? .module
