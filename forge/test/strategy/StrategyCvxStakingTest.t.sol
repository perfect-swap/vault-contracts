// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

//import "forge-std/Test.sol";
import "../../../node_modules/forge-std/src/Test.sol";

// Users
import "../users/VaultUser.sol";
// Interfaces
import "../interfaces/IERC20Like.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IStrategy.sol";
import "../../../contracts/PRFCT/vaults/PrfctVaultV7.sol";
import "../../../contracts/PRFCT/interfaces/common/IERC20Extended.sol";
import "../../../contracts/PRFCT/strategies/Curve/StrategyConvexStaking.sol";
import "../../../contracts/PRFCT/strategies/Common/StratFeeManager.sol";
import "./BaseStrategyTest.t.sol";

contract StrategyCvxStakingTest is BaseStrategyTest {

    IStrategy constant PROD_STRAT = IStrategy(0x2486c5fa59Ba480F604D5A99A6DAF3ef8A5b4D76);
    address constant uniV3 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant native = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant cvxCrv = 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7;
    address constant ethCrvPool = 0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511;
    address constant cvxCrvPool = 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8;
    address constant threePoolLp = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address constant threePool = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant triCrypto = 0xD51a44d3FaE010294C616388b506AcdA1bfAAE46;
    address constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant fxs = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
    address constant ethFxsPool = 0x941Eb6F616114e4Ecaa85377945EA306002612FE;
    address constant cvxFxsPool = 0xd658A338613198204DCa1143Ac3F01A722b5d94A;
    address constant cvxFxs = 0xFEEf77d3f69374f66429C91d732A244f074bdf74;
    address constant fpis = 0xc2544A32872A91F4A553b404C6950e89De901fdb;
    address constant cvxFpis = 0xa2847348b58CEd0cA58d23c7e9106A49f1427Df6;
    address constant cvxFpisPool = 0xfBB481A443382416357fA81F16dB5A725DC6ceC8;
    address constant fxsFpisPool = 0xD4e2fdC354c5DFfb865798Ca98c2b9d5382F687C;
    address constant prisma = 0xdA47862a83dac0c112BA89c6abC2159b95afd71C;
    address constant prismaEthPool = 0x322135Dd9cBAE8Afa84727d9aE1434b5B3EBA44B;
    address constant cvxPrisma = 0x34635280737b5BFe6c7DC2FC3065D60d66e78185;
    address constant cvxPrismaPool = 0x3b21C2868B6028CfB38Ff86127eF22E68d16d53B;

    address[9] nativeToCvxCrv = [native, ethCrvPool, crv, cvxCrvPool, cvxCrv];
    uint[3][4] nativeToCvxCrvParams = [[0, 1, 3], [0, 1, 1]];

    address[9] nativeToCvxFxs = [native, ethFxsPool, fxs, cvxFxsPool, cvxFxs];
    uint[3][4] nativeToCvxFxsParams = [[0, 1, 3], [0, 1, 3]];

    address[9] nativeToCvxFpis = [native, ethFxsPool, fxs, fxsFpisPool, fpis, cvxFpisPool, cvxFpis];
    uint[3][4] nativeToCvxFpisParams = [[0, 1, 3], [0, 1, 3], [0, 1, 1]];

    address[9] nativeToCvxPrisma = [native, prismaEthPool, prisma, cvxPrismaPool, cvxPrisma];
    uint[3][4] nativeToCvxPrismaParams = [[0, 1, 3], [0, 1, 1]];

    address[9] threePoolToNativeRoute = [threePoolLp, threePool, usdt, triCrypto, native];
    uint[3][4] threePoolToNativeParams = [[0, 2, 12], [0, 2, 3]];

    address[9] fxsToNativeRoute = [fxs, ethFxsPool, native];
    uint[3][4] fxsToNativeParams = [[1, 0, 3]];

    address[9] fpisToNativeRoute = [fpis, fxsFpisPool, fxs, ethFxsPool, native];
    uint[3][4] fpisToNativeParams = [[1, 0, 3], [1, 0, 3]];

    address[9] rewardRoute = fpisToNativeRoute;
    uint[3][4] rewardParams = fpisToNativeParams;
    uint rewardMinAmount = 1e19;

    address want = cvxPrisma;
    address staking = 0x0c73f1cFd5C9dFc150C8707Aa47Acbd14F0BE108;
    StrategyConvexStaking.CurveRoute nativeToWant = StrategyConvexStaking.CurveRoute(
        nativeToCvxPrisma, nativeToCvxPrismaParams, 0
    );

//    address want = cvxFpis;
//    address staking = 0xfA87DB3EAa93B7293021e38416650D2E666bC483;
//    StrategyConvexStaking.CurveRoute nativeToWant = StrategyConvexStaking.CurveRoute(
//        nativeToCvxFpis, nativeToCvxFpisParams, 0
//    );

    uint24[] fee3000 = [3000];
    address uniV3Reward = usdc;
    bytes uniV3RewardPath = routeToPath(route(uniV3Reward, native), fee3000);
    uint uniV3Amount = 200 * 1e6;

    IVault vault;
    StrategyConvexStaking strategy;
    VaultUser user;
    uint256 wantAmount = 500000 ether;

    function setUp() public {
        PrfctVaultV7 vaultV7 = new PrfctVaultV7();
        vault = IVault(address(vaultV7));
        strategy = new StrategyConvexStaking();
        user = new VaultUser();

        vaultV7.initialize(IStrategyV7(address(strategy)), "TestVault", "testVault", 0);

        StrategyFeeManagerInitializable.CommonAddresses memory commons = StrategyFeeManagerInitializable.CommonAddresses({
        vault : address(vault),
        unirouter : uniV3,
        keeper : PROD_STRAT.keeper(),
        strategist : address(user),
        prfctFeeRecipient : PROD_STRAT.prfctFeeRecipient(),
        prfctFeeConfig : PROD_STRAT.prfctFeeConfig()
        });

        strategy.initialize(want, staking, nativeToWant, commons);
        console.log("Strategy initialized");

//        strategy.addReward(rewardRoute, rewardParams, rewardMinAmount);
//        strategy.setCurveSwapMinAmount(1);

        deal(vault.want(), address(user), wantAmount);
        initBase(vault, IStrategy(address(strategy)));
    }

    function test_addRewards() external {
        strategy.resetRewards();
        strategy.resetRewardsV3();

        console.log("Add reward");
        address[9] memory _route;
        _route[0] = strategy.crv();
        uint[3][4] memory _params;
        _params[0][0] = 11;
        strategy.addReward(_route, _params, 1);
        _route[0] = strategy.cvx();
        strategy.addReward(_route, _params, 1);
        address[] memory routeToNative = strategy.rewardToNative(0);
        uint[3][4] memory swapParams = strategy.rewardToNativeParams(0);
        uint minAmount = strategy.rewards(0);
        assertEq(routeToNative[0], strategy.crv(), "!crv");
        assertEq(swapParams[0][0], 11, "!params");
        assertEq(minAmount, 1, "!minAmount");
        routeToNative = strategy.rewardToNative(1);
        assertEq(routeToNative[0], strategy.cvx(), "!cvx");
        vm.expectRevert();
        strategy.rewards(2);

        console.log("Add rewardV3");
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        strategy.addRewardV3(routeToPath(route(strategy.crv(), strategy.native()), fees), 1);
        address token0;
        bytes memory b;
        (token0, b, minAmount) = strategy.rewardsV3(0);
        assertEq(token0, strategy.crv(), "!crv");
        assertEq(minAmount, 1, "!minAmount");
        vm.expectRevert();
        strategy.rewardsV3(1);


        console.log("rewardV3ToNative");
        print(strategy.rewardV3ToNative());
        console.log("rewardToNative");
        print(strategy.rewardToNative());
        console.log("nativeToWant");
        print(strategy.nativeToWantRoute());

        strategy.resetRewards();
        strategy.resetRewardsV3();
        vm.expectRevert();
        strategy.rewards(0);
        vm.expectRevert();
        strategy.rewardsV3(0);
    }

    function test_rewards() external {
        _depositIntoVault(user, wantAmount);
        skip(1 days);

        address[] memory rewards = new address[](strategy.rewardsLength() + strategy.rewardsV3Length());
        for(uint i; i < strategy.rewardsLength(); ++i) {
            rewards[i] = strategy.rewardToNative(i)[0];
        }
        for(uint i; i < strategy.rewardsV3Length(); ++i) {
            rewards[strategy.rewardsLength() + i] = strategy.rewardV3ToNative(i)[0];
        }

        console.log("Claim rewards on Convex");
        strategy.staking().getReward(address(strategy));
        uint crvBal = IERC20(strategy.crv()).balanceOf(address(strategy));
        uint cvxBal = IERC20(strategy.cvx()).balanceOf(address(strategy));
        uint nativeBal = IERC20(native).balanceOf(address(strategy));
        console.log("CRV", crvBal);
        console.log("CVX", cvxBal);
        for (uint i; i < rewards.length; ++i) {
            uint bal = IERC20(rewards[i]).balanceOf(address(strategy));
            console2.log(IERC20Extended(rewards[i]).symbol(), bal);
        }
        console.log("WETH", nativeBal);
//        deal(strategy.crv(), address(strategy), 1e20);
        deal(strategy.cvx(), address(strategy), 1e20);

        console.log("Harvest");
        strategy.harvest();
        crvBal = IERC20(strategy.crv()).balanceOf(address(strategy));
        cvxBal = IERC20(strategy.cvx()).balanceOf(address(strategy));
        nativeBal = IERC20(native).balanceOf(address(strategy));
        console.log("CRV", crvBal);
        console.log("CVX", cvxBal);
        for (uint i; i < rewards.length; ++i) {
            uint bal = IERC20(rewards[i]).balanceOf(address(strategy));
            console2.log(IERC20Extended(rewards[i]).symbol(), bal);
            assertEq(bal, 0, "Extra reward not swapped");
        }
        console.log("WETH", nativeBal);
        assertEq(crvBal, 0, "CRV not swapped");
        assertEq(crvBal, 0, "CVX not swapped");
        assertEq(nativeBal, 0, "Native not swapped");
    }

    function test_skipCurveSwap() external {
        strategy.resetRewards();
        strategy.resetRewardsV3();
        strategy.setCurveSwapMinAmount(0);

        _depositIntoVault(user, wantAmount);
        uint bal = vault.balance();
        skip(1 days);

        console.log("Harvest");
        strategy.harvest();
        assertEq(vault.balance(), bal, "Expected harvested 0");
    }

    function test_setNativeToWant() external {
        address[9] memory route;
        uint[3][4] memory params;
        route[0] = crv;
        vm.expectRevert();
        strategy.setNativeToWantRoute(route, params);

        route[0] = native;
        route[1] = crv;
        console.log("setNativeToWantRoute");
        strategy.setNativeToWantRoute(route, params);

        assertEq(strategy.nativeToWantRoute().length, 2, "!route");
        assertEq(strategy.nativeToWantRoute()[0], route[0], "!route 0");
        assertEq(strategy.nativeToWantRoute()[1], route[1], "!route 1");
        assertEq(strategy.nativeToWantParams()[0][0], params[0][0], "!params");
        assertEq(strategy.nativeToWant(), 0, "amount != 0");
    }

    function test_rewardsV3() external {
        console.log("Add reward");
        strategy.addRewardV3(uniV3RewardPath, 10);
        deal(uniV3Reward, address(strategy), uniV3Amount);
        console.log(IERC20Extended(uniV3Reward).symbol(), IERC20(uniV3Reward).balanceOf(address(strategy)));

        skip(1 days);
        console.log("Harvest");
        strategy.harvest();
        uint bal = IERC20(uniV3Reward).balanceOf(address(strategy));
        console.log(IERC20Extended(uniV3Reward).symbol(), bal);
        assertEq(bal, 0, "Extra reward not swapped");
    }
}