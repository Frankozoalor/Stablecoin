//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeErc20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./Lib/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Frank Ozoalor
 *
 * The system is designed to be as minimal as possible and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI had no goverence, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized".
 * At no point, should the value of all collateral <= the $ backed value of all the DSC
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting
 * and redeemung DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is Very loosely based on the MarkerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;
    ////////////////////
    // Errors        ///
    ///////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedLengthMustMatch();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__HealthFactorBelowMin(uint256 HealthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__CollateralTokenAlreadyRegistered();
    error DSCEngine__CollateralLstMinOutPutTokens();

    //////////////////////
    // State Variables ///
    /////////////////////

    uint256 private constant ADDITIONAL_FEED_PERCISION = 1e10;
    uint256 private constant PERCISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_PERCISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeed;
    mapping(address user => mapping(address token => uint256 amount)) public s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) public s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////
    // Events          ///
    /////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeem(address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount);

    ////////////////////
    // Modifiers     ///
    ///////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /////////////////////////////
    // Constructor    ///////////
    ////////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedLengthMustMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            if (s_priceFeed[tokenAddresses[i]] != address(0)) revert DSCEngine__CollateralTokenAlreadyRegistered();
            s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////////
    // External Functions    ///
    ////////////////////////////

    /**
     * @param collateralTokenAddress The address of the token to deposit as collateral
     * @param collateralamount The amount of collateral to deposit
     */
    function depositCollateral(address collateralTokenAddress, uint256 collateralamount)
        public
        moreThanZero(collateralamount)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralTokenAddress] += collateralamount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralamount);
        IERC20(collateralTokenAddress).safeTransferFrom(msg.sender, address(this), collateralamount);
    }

    /**
     * @param amountDscToMint The amount of DSC to mint
     */
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
        _revertIfhealthFactorisBroken(msg.sender);
    }
    /*
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice This function will deposit your collateral and mint DSC in one transaction
    */

    function depositCollateralAndMintDsc(
        address collateralTokenAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(collateralTokenAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }
    /*
    * @param tokenCollateralAddress The address of the token to redeem 
    * @param amountCollateral The amount of collateral to redeem
    * @notice Users can use this function to redeem their collateral.
    */

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /*
    
    * @param amount The amount of DSC to burn
    * @notice This function will burn your DSC
    */
    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
    }

    /*
    * @param tokenCollateralAddress The address of the token to redeem 
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * @notice This function will burn your DSC and redeem Collateral in one transaction
    */
    function RedeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /*
    * @param collateral The erc20 collateral address to liquidate from the user.
    * @param user The user who has broken the health factor. Their _healtfactor should be below MIN_HEALTH_FACTOR.
    * @param debtToRecover The amount of DSC you want to burn to improve the user's health factor
    * @notice You can partially liquidate user
    * @notice You will get a liquidation bonus for taking the users funds
    * @notice This function working assumes the protocol will be roughly 200% over collateralized in order for this to work
    */
    function liquidate(address collateralAddress, address user, uint256 debtToRecover)
        public
        moreThanZero(debtToRecover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _getHealthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }

        // if covering 100 DSC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralAddress, debtToRecover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PERCISION;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        uint256 totalDepositedCollateral = s_collateralDeposited[user][collateralAddress];
        if (tokenAmountFromDebtCovered < totalDepositedCollateral && totalCollateralToRedeem > totalDepositedCollateral)
        {
            totalCollateralToRedeem = totalDepositedCollateral;
        }
        _redeemCollateral(user, msg.sender, collateralAddress, totalCollateralToRedeem);

        _burnDsc(user, msg.sender, debtToRecover);

        uint256 endingUserHealthFactor = _revertIfhealthFactorisBroken(user);
        if (endingUserHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }
    }

    /**
     * @param totalDscMinted the total number of of DSC minted by the user
     * @param collateralValueInUsd The collateral value in usd of collateral deposited
     *  @notice Users can call this function to calculate their health factor.
     */
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }
    /**
     * @param token the token address of the token you want to retrieve the amount
     * @param usdAmountInWei The value of tokens in usd you want to retrieve
     *  @notice Users can call this function to get the number of token you can purchase for a given amount.
     */

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PERCISION) / (uint256(price) * ADDITIONAL_FEED_PERCISION);
    }

    /**
     * @param token the token address you want to retrieve its Price Feed.
     *  @notice This function is used to get the priceFeed of a tokenAddress.
     */
    function getTokenPriceFeed(address token) public view returns (int256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return price;
    }
    /**
     * @param user The address of the user you want to retrieve its account information
     *  @notice This function is used to get the the account information of a user.
     */

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    /**
     * @notice A getter function to get the all the token addresses used as collateral in the system.
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /**
     * @param user The address of t he user toget collateral Balance
     *  @param token The token address of the collateral to check balance of.
     * @notice A getter function to get the collateral balance of a user.
     */
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
    /**
     * @param token The token address to get the current priceFeed
     * @notice Function to get the price feed of a collateral token
     */

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeed[token];
    }

    ////////////////////////////////////
    // Internal & Private Functions  ///
    ///////////////////////////////////

    /**
     * @param from The address of the user to redeem the token from
     * @param to The address of the user to send the redeemed token from
     * @param tokenCollateralAddress The address of the token to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @notice Users can use this function to redeem their collateral.
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeem(from, to, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransfer(to, amountCollateral);
    }

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factor being broken
     */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        IERC20(i_dsc).safeTransferFrom(dscFrom, address(this), amountDscToBurn);
        i_dsc.burn(amountDscToBurn);
    }
    /**
     * @param totalDscMinted the total number of of DSC minted by the user
     * @param collateralValueInUsd The collateral value in usd of collateral deposited
     *  @notice Thisis an interal function used to calcuate health factor of a user
     */

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        return (collateralValueInUsd * LIQUIDATION_THRESHOLD * 1e18) / (LIQUIDATION_PERCISION * totalDscMinted);
    }

    /**
     * @param user the total number of of DSC minted by the user
     *  @notice Internal function to check if a user's, healthFactor is< 1;
     */
    function _revertIfhealthFactorisBroken(address user) internal view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 userHealthFactor = _calculateHealthFactor(totalDSCMinted, collateralValueInUsd);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBelowMin(userHealthFactor);
        }
        return userHealthFactor;
    }

    /**
     * @param user the total number of of DSC minted by the user
     *  @notice Internal function to get the healthFactor of user
     */
    function _getHealthFactor(address user) internal view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 userHealthFactor = _calculateHealthFactor(totalDSCMinted, collateralValueInUsd);
        return userHealthFactor;
    }

    /////////////////////////////
    // Getter Functions      ///
    ////////////////////////////

    /**
     * @notice This function gets the account information of a user
     * ie, the user's totalDSCMinted and the Collateral value in usd.
     * @param user, the user to get the account information
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /**
     * @param user The address of the user to get the total collateral value of assetdeposited
     */
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUSD) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getUsdValue(token, amount);
        }
        return totalCollateralValueInUSD;
    }

    /**
     * @param token The token address of the collateral
     * @param amount The amount of token you want check its price
     *  i.e, fora given amount of tokenX,how much is it in USD
     * @notice Function to get the the current usd value of token and amount
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PERCISION) * amount) / PERCISION;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUsd);
    }
}
