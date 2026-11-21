//
//  main.swift — entry point of the diagnostics test executable (`mise run test`).
//  Add each new suite's run function here.
//

configTests()
sysPanelTests()
coreTests()
pollerTests()
hubTests()
agentsTests()
layoutTests()
collectorTests()
usagePanelTests()
TestKit.finish()
