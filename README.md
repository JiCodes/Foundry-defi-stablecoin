# Over collateralized algorithm stable coin

It is similar to MakerDAO's DAI

1. (Relative Stablity) Anchored or Pegged -> $1.00
    1. Chainlink Price Feed.
    2. Set a function to exchange ETH & BTC -> $$
2. Stablity Mechanism (Minting): Algorithm (Decentralized)
    1. People can only mint the stablecoin with enough collateral (coded)
3. Collateral: Exogenous (Crypto)
    1. wETH
    2. wBTC


- calculate health factor function
- set health factor if debt is 0
- 


- Fuzz/Invariant Testing
    1. What are our invariants/properties?

in Foundry: 

Foundry fuzzing = stateless fuzzing
Foundry invariant = stateful fuzzing

Fuzz tests = Random Data to one function
Invariant tests = Random Data & Random function calls to many functions


stafefull fuzz: use "invariant_" keyword for function

import {StdInvariant} from "forge-std/StdInvariant.sol";
function invariant_testXXX() public {}

set fuzz test params in foundry.toml
[invariant]
runs = 1000
depth = 128
fail_on_revert = true // this will narrow down function calls