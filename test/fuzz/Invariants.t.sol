// // SPDX-License-Identifier: MIT

// // Handler-based Fuzz(invairant) tests
// // set 'revert_on_fail = true' in the fuzzing config to make the fuzzer revert on the first failure

// // Have our invairants aka properties been violated?
// // what are our invariants?
// // 1. The total supply of DSC should be less than the total value of collateral
// // 2. Getter view functions should never revert <- evergreen invariant

// pragma solidity ^0.8.19;

// import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {Handler} from "./Handler.t.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;
//     Handler handler;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dscEngine, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         // targetContract(address(dscEngine)); // targetContract(): call all the functions on the dscEngine
        
//         targetContract(address(handler));
//         // hey don't call redeemCollateral, unless there is collateral to redeem -> use handler
//     }

//     function invariant_protocalMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocal
//         // compare it to all the debt(DSC)

//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);
//         uint256 totalProtocalValue = wethValue + wbtcValue;

//         assert(totalProtocalValue >= totalSupply);
//     }
// }
