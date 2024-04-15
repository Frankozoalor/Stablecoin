//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployDSC;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("Liquidator");

    int256 public constant ETH_USD_PRICE = 2000e8;
    uint8 public constant DECIMALS = 8;

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant DSC_AMOUNT_TO_MINT = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_OUTPUT = 7 ether;
    uint256 private constant ADDITIONAL_FEED_PERCISION = 1e10;
    uint256 private constant PERCISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    uint256 collateralToCover = 20 ether;

    // "liquidate(address,address,uint256)": "26c01303",

    function setUp() public {
        deployDSC = new DeployDSC();
        (dsc, engine, config) = deployDSC.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /////////////////////////////
    // PRICE TEST       ////////
    ////////////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    /////////////////////////////
    // Construction Tests ///////
    ////////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedLengthMustMatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testArrayLengthMatch() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        uint256 tokenAddressLength = tokenAddresses.length;
        uint256 PriceFeedLength = priceFeedAddresses.length;
        assertEq(tokenAddressLength, PriceFeedLength);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100e18;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        console.log("actualWeth", actualWeth);
        assertEq(expectedWeth, actualWeth);
    }

    function test_getAccountCollateralValueInUsd() public depositedCollateral {
        uint256 accountCollateral = AMOUNT_COLLATERAL;
        int256 priceFeed = engine.getTokenPriceFeed(weth);
        uint256 totalCollateralValueInUSD = engine.getAccountCollateralValueInUsd(USER);
        uint256 collateralValueAdjusted = uint256(priceFeed) * ADDITIONAL_FEED_PERCISION * accountCollateral / PERCISION;
        assertEq(totalCollateralValueInUSD, collateralValueAdjusted);
    }

    function testgetTokenPriceFeed() public {
        int256 expectedPriceFeed = 2000e8;
        int256 priceFeed = engine.getTokenPriceFeed(weth);
        assertEq(priceFeed, expectedPriceFeed);
    }

    function testcalculateHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.mintDSC(DSC_AMOUNT_TO_MINT);
        uint256 amountMinted = engine.s_DSCMinted(USER);
        uint256 totalCollateralValueInUSD = engine.getAccountCollateralValueInUsd(USER);
        uint256 healthFactor = engine.calculateHealthFactor(amountMinted, totalCollateralValueInUSD);
        console.log("healthFactor", healthFactor);
        assert(healthFactor >= MIN_HEALTH_FACTOR);
        vm.stopPrank();
    }

    function testMintDsc() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDSC(DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedToken() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function test_depositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_AMOUNT_TO_MINT);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        assertEq(totalDscMinted, DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testRedeemCollateralForDsc() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDSC(DSC_AMOUNT_TO_MINT);
        dsc.approve(address(engine), DSC_AMOUNT_TO_MINT);
        uint256 amountMinted = engine.s_DSCMinted(USER);
        engine.RedeemCollateralForDsc(weth, AMOUNT_COLLATERAL, DSC_AMOUNT_TO_MINT);
        uint256 collateralRedeemed = ERC20Mock(weth).balanceOf(USER);
        assertEq(AMOUNT_COLLATERAL, collateralRedeemed);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDSC(DSC_AMOUNT_TO_MINT);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 amountMinted = engine.s_DSCMinted(USER);
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(amountMinted, DSC_AMOUNT_TO_MINT);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
        vm.stopPrank();
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 collateralBalanceOfUser = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalanceOfUser, AMOUNT_COLLATERAL);
    }

    function testGetCollateralMockTokenPriceFeed() public depositedCollateral {
        address tokenPriceFeed = engine.getCollateralTokenPriceFeed(weth);
        address MockWethPriceFeed = 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496;
        assertEq(tokenPriceFeed, MockWethPriceFeed);
    }

    function testGetCollateralTokens() public depositedCollateral {
        address[] memory collateralTokens = engine.getCollateralTokens();
        address depositedToken = collateralTokens[0];
        assertEq(depositedToken, weth);
    }

    function test_Liquidate() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_AMOUNT_TO_MINT);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor < MIN_HEALTH_FACTOR);

        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(weth, collateralToCover, DSC_AMOUNT_TO_MINT);

        uint256 amountMinted = engine.s_DSCMinted(LIQUIDATOR);
        uint256 totalCollateralValueInUSD = engine.getAccountCollateralValueInUsd(LIQUIDATOR);
        uint256 healthFactor = engine.calculateHealthFactor(amountMinted, totalCollateralValueInUSD);

        dsc.approve(address(engine), DSC_AMOUNT_TO_MINT);
        engine.liquidate(weth, USER, DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
    }
}
