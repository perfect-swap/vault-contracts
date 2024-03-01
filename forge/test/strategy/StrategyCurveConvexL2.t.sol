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
import "../interfaces/IUniV3Quoter.sol";
import "../../../contracts/PRFCT/vaults/PrfctVaultV7.sol";
import "../../../contracts/PRFCT/interfaces/common/IERC20Extended.sol";
import "../../../contracts/PRFCT/strategies/Curve/StrategyCurveConvexL2.sol";
import "../../../contracts/PRFCT/strategies/Common/StratFeeManager.sol";
import "../../../contracts/PRFCT/utils/UniswapV3Utils.sol";
import "./BaseStrategyTest.t.sol";

contract StrategyCurveConvexL2Test is BaseStrategyTest {

    IVault vault;
    StrategyCurveConvexL2 strategy = new StrategyCurveConvexL2();
    VaultUser user = new VaultUser();
    uint256 wantAmount = 50000 ether;
    address want;

    function setUp() public {
        address vaultAddress = vm.envOr("VAULT", address(0));
        if (vaultAddress != address(0)) {
            vault = IVault(vaultAddress);
            strategy = StrategyCurveConvexL2(vault.strategy());
            console.log("Testing vault at", vaultAddress);
            console.log(vault.name(), vault.symbol());
        } else {
            PrfctVaultV7 vaultV7 = new PrfctVaultV7();
            vaultV7.initialize(IStrategyV7(address(strategy)), "TestVault", "testVault", 0);
            vault = IVault(address(vaultV7));

            bytes memory initData = vm.envBytes("INIT_DATA");
            (bool success,) = address(strategy).call(initData);
            assertTrue(success, "Strategy initialize not success");

            strategy.setVault(address(vault));
            assertEq(strategy.vault(), address(vault), "Vault not set");
            console.log("Vault initialized", IERC20Extended(vault.want()).symbol());
        }
        want = strategy.want();
        deal(vault.want(), address(user), wantAmount);
        initBase(vault, IStrategy(address(strategy)));
    }

    function test_initWithNoPid() external {
        // only if convex
        if (strategy.rewardPool() == address(0)) return;

        PrfctVaultV7 vaultV7 = new PrfctVaultV7();
        IVault vaultNoPid = IVault(address(vaultV7));
        StrategyCurveConvexL2 strategyNoPid = new StrategyCurveConvexL2();

        deal(want, address(user), wantAmount);

        vaultV7.initialize(IStrategyV7(address(strategyNoPid)), "TestVault", "testVault", 0);
        StrategyFeeManagerInitializable.CommonAddresses memory commons = StrategyFeeManagerInitializable.CommonAddresses({
            vault : address(vaultNoPid),
            unirouter : strategy.unirouter(),
            keeper : strategy.keeper(),
            strategist : address(user),
            prfctFeeRecipient : strategy.prfctFeeRecipient(),
            prfctFeeConfig : address(strategy.prfctFeeConfig())
        });
        address[] memory rewards = new address[](strategy.rewardsLength());
        for (uint i; i < strategy.rewardsLength(); ++i) {
            rewards[i] = strategy.rewards(i);
        }
        console.log("Init Strategy NO_PID");
        strategyNoPid.initialize(strategy.native(), want, strategy.gauge(), strategy.NO_PID(), strategy.depositToken(), rewards, commons);

        user.approve(want, address(vaultNoPid), wantAmount);
        user.depositAll(vaultNoPid);
        user.withdrawAll(vaultNoPid);
        uint wantBalanceFinal = IERC20(want).balanceOf(address(user));
        console.log("Final user want balance", wantBalanceFinal);
        assertLe(wantBalanceFinal, wantAmount, "Expected wantBalanceFinal <= wantAmount");
        assertGt(wantBalanceFinal, wantAmount * 99 / 100, "Expected wantBalanceFinal > wantAmount * 99 / 100");
    }

    function test_setConvexPid() external {
        // only if convex
        if (strategy.rewardPool() == address(0)) return;
        uint pid = strategy.pid();

        address rewardPool = strategy.rewardPool();
        _depositIntoVault(user, wantAmount);

        uint rewardPoolBal = IConvexRewardPool(rewardPool).balanceOf(address(strategy));
        assertEq(vault.balance(), rewardPoolBal, "RewardPool balance != vault balance");

        console.log("setConvexPid NO_PID switches to Curve");
        vm.startPrank(strategy.owner());
        strategy.setConvexPid(strategy.NO_PID());
        vm.stopPrank();
        rewardPoolBal = IConvexRewardPool(rewardPool).balanceOf(address(strategy));
        assertEq(rewardPoolBal, 0, "RewardPool balance != 0");
        uint gaugeBal = IRewardsGauge(strategy.gauge()).balanceOf(address(strategy));
        assertEq(vault.balance(), gaugeBal, "Gauge balance != vault balance");
        user.withdrawAll(vault);
        uint userBal = IERC20(want).balanceOf(address(user));
        assertLe(userBal, wantAmount, "Expected userBal <= wantAmount");
        assertGt(userBal, wantAmount * 99 / 100, "Expected userBal > wantAmount * 99 / 100");

        _depositIntoVault(user, userBal);
        console.log("setConvexPid bad pid reverts");
        vm.startPrank(strategy.owner());
        vm.expectRevert();
        strategy.setConvexPid(1);
        vm.stopPrank();

        console.log("setConvexPid valid pid switches to Convex");
        vm.prank(strategy.owner());
        strategy.setConvexPid(pid);
        rewardPoolBal = IConvexRewardPool(rewardPool).balanceOf(address(strategy));
        assertEq(vault.balance(), rewardPoolBal, "RewardPool balance != vault balance");
        gaugeBal = IRewardsGauge(strategy.gauge()).balanceOf(address(strategy));
        assertEq(gaugeBal, 0, "Gauge balance != 0");
        user.withdrawAll(vault);
        uint userBalFinal = IERC20(want).balanceOf(address(user));
        assertLe(userBalFinal, userBal, "Expected userBalFinal <= userBal");
        assertGt(userBalFinal, userBal * 99 / 100, "Expected userBalFinal > userBal * 99 / 100");
    }

    function test_setCrvMintable() external {
        // revert all calls to minter.mint
        vm.mockCallRevert(
            address(strategy.minter()),
            abi.encodeWithSelector(ICrvMinter.mint.selector, strategy.gauge()),
            "MINTER_CALLED"
        );

        // no mint if convex
        if (strategy.rewardPool() != address(0)) {
            strategy.harvest();
        }

        console.log("setConvexPid NO_PID");
        vm.startPrank(strategy.owner());
        strategy.setConvexPid(strategy.NO_PID());
        vm.stopPrank();

        console.log("setCrvMintable false not expecting mint");
        vm.prank(strategy.keeper());
        strategy.setCrvMintable(false);
        strategy.harvest();

        console.log("setCrvMintable true expecting mint");
        vm.prank(strategy.keeper());
        strategy.setCrvMintable(true);
        vm.expectRevert("MINTER_CALLED");
        strategy.harvest();
    }

    function test_rewards() external {
        _depositIntoVault(user, wantAmount);
        skip(1 days);

        // if convex
        if (strategy.rewardPool() != address(0)) {
            console.log("Claim rewards on Convex");
            IConvexRewardPool(strategy.rewardPool()).getReward(address(strategy));
        } else {
            console.log("Claim rewards on Curve");
            if (strategy.isCurveRewardsClaimable()) {
                IRewardsGauge(strategy.gauge()).claim_rewards(address(strategy));
            }
            if (strategy.isCrvMintable()) {
                vm.startPrank(address(strategy));
                strategy.minter().mint(strategy.gauge());
                vm.stopPrank();
            }
        }

        for (uint i; i < strategy.rewardsLength(); ++i) {
            uint bal = IERC20(strategy.rewards(i)).balanceOf(address(strategy));
            console.log(IERC20Extended(strategy.rewards(i)).symbol(), bal);
        }

        console.log("Harvest");
        strategy.harvest();

        for (uint i; i < strategy.rewardsLength(); ++i) {
            uint bal = IERC20(strategy.rewards(i)).balanceOf(address(strategy));
            console.log(IERC20Extended(strategy.rewards(i)).symbol(), bal);
        }
    }
}