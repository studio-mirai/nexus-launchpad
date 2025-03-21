# Nexus Launchpad

## Launch

### Launch States

| NAME          | DESCRIPTION                                                                                                 |
|---------------|-------------------------------------------------------------------------------------------------------------|
| SUPPLYING     | Initial state where items can be added to the launch. Launch remains in this state until total supply is met|
| SCHEDULING    | State for configuring launch phases and their time ranges                                                   |
| WHITELISTING  | State for configuring whitelist for each phase                                                              |
| READY         | Launch is ready to begin minting with first phase scheduled                                                 |
| MINTING       | Active minting state during a phase's time window                                                           |
| PAUSED        | Temporarily paused minting state                                                                            |
| COMPLETED     | Final state after all phases are complete                                                                   |

## Phase

## Mint