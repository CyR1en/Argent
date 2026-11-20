import ArgentCore
import ArgentRoll
import Foundation
import Testing
@testable import ArgentRemoveHelper

/// The helper that holds Remove's model (docs/remove-plan.md, section 4.5). Package H2 builds it and fills this suite: its
/// scheduler, loop and fusion against the tensors the conversion recorded, and the folder it serves driven by `FolderEngine`.
@Suite struct RemoveHelperTests {
    @Test func theFolderTheHelperServesIsTheBridges() {
        // Unbuilt, package H2. What both servers write is pinned in ArgentCoreTests' RemovalContractTests.
        #expect(RemovalFolder.engineFile == "engine.json" && RemovalFolder.prepareFile == "prepare.json")
    }
}
