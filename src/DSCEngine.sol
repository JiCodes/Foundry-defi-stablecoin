// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";

/*
 * @title DSCEngine
 * @author: JiCodes
 *
 * @dev This system is designed to be as minimal as possible, and have the tokens maintain a 1 token = $1 USD peg.
 * This stablecoin has the properties:
 * - Exogenous Collatoral (ETH & BTC)
 * - Algorithmic stable
 * - Relative Stability (Pegged to USD)
 *
 * It is similar to MakerDAO's DAI, if DAI had no governance, no fees, and was only backed by wrapped ETH and wrapped BTC.
 *
 * DSC system should always be "overcollatoralized". At no point should the value of all collateral <= the $ backed value of allthe DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depoisiting and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS(DAI) system, but is much simpler and has no governance.
 */

contract DSCEngine is ReentrancyGuard {
    // Errors
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    // error DSCEngine__DepositCollateralFailed();
    // error DSCEngine__RedeemCollateralFailed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    // State Variables
    uint256 private constant ADDTIONAL_FEED_PRECISION = 1e10; // 10 decimals
    uint256 private constant PRECISION = 1e18; // 10 decimals
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollatoralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    // Events
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    // Modifiers
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    // Functions
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH / USD, BTC / USD, etc.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // External Functions

    /*
     * @param tokenCollateralAddress: The address of the token to be deposited as collateral
     * @param amountCollateral: The amount of collateral to be deposited
     * @param amountDscToMint: The amount of decentralized stable coin to mint
     * @notice this function will deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI pattern (check, effects, interactions)
     * @param tokenCollateralAddress: The address of the token to be deposited as collateral
     * @param amountCollateral: The amount of collateral to be deposited
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    /*
     * @param tokenCollateralAddress: The collateral address to redeem 
     * @param amountCollateral: The amount of collateral to redeem
     * @param amountDscToBurn: The amount of DSC to burn
     * This function burns DSC and redeems underlaying collateral in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 after collateral is pulled out
    // DRY: don't repeat yourself, refactor later
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI pattern (check, effects, interactions)
     * @param amountDscToMint The amount of decentralized stable coin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC, with $100 ETH collateral), revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender, msg.sender, amount);
        // _revertIfHealthFactorIsBroken(msg.sender); // not needed, because they are burning DSC
    }

    // If we do start to nearing undercollatoralization, we need someone to liquidate the user's position(collateral)

    // $75 backing $50 DSC
    // Liquidator burns off the $50 DSC and takes the $75 backing

    // If someone is almost undercollatoralized, we will pay you to liquidate them!

    /*
     * @param collateral: The collateral address to be liquidated from the user
     * @param user: The user who has the brocken the health factor. Their _healthFactor should be bellow MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC to burn to improve the user's health factor
     * @notice you can partially liquidate a user
     * @notice you will get a liquidation bonus fot taking the users funds
     * @notice This function working assumes the protocal will be roughly 200% overcollatoralized in order for this to work
     * @notice A known bug would be if the protocal were 100% or less collaterlized, then we wouldn't be able to incentivize liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * Follows CEI pattern (check, effects, interactions)
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn their DSC "debt"
        // and take their collateral
        // Bad user: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 DSC => ?? $ ETH
        // 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give liquidator a 10% bonus
        // So we are giving the liquidator $110 worth of wETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocal is insolvent
        // And we sweep extra amounts into a treasury
        // 0.05 ETH * .1 = 0.005 ETH getting 0.005 ETH bonus
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // you need burn the DSC
        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external {}

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    // Private & Internal Functions

    /*
     * @dev Low-level private function, do not call unless the function calling it is checking for health factor being broken
     */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(to, from, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns how close to liquidation the user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // 1. Get the value of all collateral
        // 2. Get total DSC minted
        // 3. Return the ratio

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        if (totalDscMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = (75 / 100) < 1

        // $1000 ETH / 100 DSC
        // 1000 * 50 = 50000 / 100 = (500 / 100) > 1

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check health factor(do they have engough collateral value?)
    // 2. If not, revert
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    // Public & External View Functions

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH  ETH??
        // $2000 / ETH.  $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e18) / ($2000 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDTIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount deposited, and map it to the price, get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amountDeposited = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amountDeposited);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // 1 ETH = $1000
        // the returned value from CL will be 1000 * 1e8
        return (uint256(price) * ADDTIONAL_FEED_PRECISION * amount) / PRECISION; // ((1000 * 1e8 * 1e10) * 1000 * 1e18)/ 1e18
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
}
