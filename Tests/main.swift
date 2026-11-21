//
//  main.swift — entry point of the diagnostics test executable (`mise run test`).
//  Add each new suite's run function here.
//

configTests()
configInitTests()
sysPanelTests()
coreTests()
pollerTests()
hubTests()
agentsTests()
backgroundTests()
collectorTests()
usagePanelTests()
TestKit.finish()
