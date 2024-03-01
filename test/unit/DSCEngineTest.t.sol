// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    DSCEngine public dsce;
    HelperConfig public config;
    DecentralizedStableCoin public dsc;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;
    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;
    uint256 public constant AMOUNT_COLLATERAL = 1 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 1 ether;
    uint256 public constant STARTING_user_BALANCE = 1 ether;
    uint256 public constant AMOUNT_TO_MINT_AND_BREAK_HEALTHFACTOR = 2000e18; // 1 ether = 2000 DSC -> Collateral =1e19 wei = 20000DSC; 20000 gives a healthFactor of 5e35, so this cannot be true? There is a conversion of the DSC to Wei necessary in the calculation? //@notice this needs to be in WEI?
    uint256 public constant AMOUNT_TO_MINT = 100 ether;

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();
        if (block.chainid == 31337) {
            vm.deal(user, STARTING_user_BALANCE);
        }
        ERC20Mock(weth).mint(user, STARTING_user_BALANCE);
        // ERC20Mock(wbtc).mint(user, STARTING_user_BALANCE);
    }

    ///////////////////////////
    /// Constructor Tests  ////
    ///////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////////////
    /// Price Tests  ////////
    /////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    //////////////////////////////////
    /// DepositCollateral Tests  /////
    //////////////////////////////////

    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapporvedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testNonReEntrant() public depositedCollateral {
        vm.expectRevert();
        (bool success,) =
            address(this).call(abi.encodePacked("depositCollateral(address,uint256)", weth, AMOUNT_COLLATERAL));
    }

    function testNonReEntrant1() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert();
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDSC(0);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        dsce.mintDSC(AMOUNT_TO_MINT);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    function testMintWhichBreaksHealthFactor() public depositedCollateral {
        vm.startPrank(user);
        // (uint256 totalDSCMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        // console.log(
        //     "Accountinformation totalDSCMinted, collateralValueInUsd before:", totalDSCMinted, collateralValueInUsd
        // );
        uint256 healthFactor = 5e17;
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthFactor));
        dsce.mintDSC(AMOUNT_TO_MINT_AND_BREAK_HEALTHFACTOR);

        // (totalDSCMinted, collateralValueInUsd) = dsce.getAccountInformation(user);
        // console.log(
        //     "Accountinformation totalDSCMinted, collateralValueInUsd after:", totalDSCMinted, collateralValueInUsd
        // );
        //console.log("Healthfactor after:", dsce.getHealthFactor(user));
        vm.stopPrank();
    }

    function testIfLiquidationRevertsWhenHealthFactorIsOk() public depositedCollateral {
        ERC20Mock(weth).mint(liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, user, AMOUNT_TO_MINT);
        dsc.approve(address(dsce), AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    // function testIfLiquidationIsPossible() public depositedCollateral {
    //     AggregatorV3Interface priceFeed = AggregatorV3Interface(DSCEngine.s_priceFeeds[token]);
    //     (, int256 price,,,) = priceFeed.latestRoundData();
    // }

    function testRedeemIfHealthFactorBreaks() public depositedCollateral {
        uint256 debtToCover = 1000 ether; // Still a good healthFactor of 1e18
        uint256 collateralAmountToRedeem = 1 ether; // Then the healthFactor is obviously also 0 due to multiplication with 0
        vm.startPrank(user);
        dsce.mintDSC(debtToCover);
        uint256 healthFactor = 0;
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthFactor));
        dsce.redeemCollateral(weth, collateralAmountToRedeem);
        vm.stopPrank();
    }

// more testing needed
// maybe done in the future

}
