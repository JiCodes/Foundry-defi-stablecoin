// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Handler is going to narrow down the scope of the fuzzing to a single function

import {Test} from "forge-std/Test.sol";
import{DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // the max unit96 value

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;
        
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    function mintDsc(uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT_SIZE); // bound the amount to 1 and MAX_DEPOSIT_SIZE (type(uint96).max)
        
        
        vm.startPrank(msg.sender);
        dscEngine.mintDsc(amount);
        vm.stopPrank();
    }

    // redeem collateral
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE); // bound the amountCollateral to 1 and MAX_DEPOSIT_SIZE (type(uint96).max)
        
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);   
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        dscEngine.redeemCollateral(address(collateral), amountCollateral);

    }

    // Helper functions
    function _getCollateralFromSeed(uint256 collaterallSeed) private view returns(ERC20Mock) {
        if(collaterallSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}