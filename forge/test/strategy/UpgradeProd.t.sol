// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

//import "forge-std/Test.sol";
import "../../../node_modules/forge-std/src/Test.sol";

// Users
import "../users/VaultUser.sol";
// Interfaces
import "../interfaces/IVault.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IERC20Like.sol";
import "../utils/Utils.sol";
import "../../../contracts/PRFCT/vaults/PrfctVaultV7.sol";

contract UpgradeProd is Test {

    uint256 wantAmount = 5000000 ether;

    IVault vault;
    IStrategy strategy;
    VaultUser user;

    function setUp() public {
        address _vault = vm.envOr("VAULT", address(0));
        address _strat = vm.envAddress("NEW_STRAT");
        strategy = IStrategy(_strat);
        if (_vault == address(0)) {
            _vault = strategy.vault();
        } else {
            vm.prank(strategy.owner());
            strategy.setVault(_vault);
        }
        console.log("Upgrading vault at", _vault);
        vault = IVault(_vault);
        console.log(vault.name(), vault.symbol());
        user = new VaultUser();
        deal(vault.want(), address(user), wantAmount);
    }

    function test_prodUpgrade() external {
        uint vaultBalance = vault.balance();
        uint pps = vault.getPricePerFullShare();

        console.log("Propose strat");
        vm.prank(vault.owner());
        vault.proposeStrat(address(strategy));
        (address _impl, ) = vault.stratCandidate();
        assertEq(_impl, address(strategy), "!proposed strategy");

        skip(vault.approvalDelay() + 1);

        console.log("Upgrade strat");
        vm.prank(vault.owner());
        vault.upgradeStrat();

        skip(1 days);
        console.log("Harvest");
        strategy.harvest();
        skip(1 days);
        uint256 vaultBalAfterHarvest = vault.balance();
        uint256 ppsAfterHarvest = vault.getPricePerFullShare();
        console.log("Balance", vaultBalance, vaultBalAfterHarvest);
        console.log("PPS", pps, ppsAfterHarvest);
        assertGt(vaultBalAfterHarvest, vaultBalance, "Harvested 0");
        assertGt(ppsAfterHarvest, pps, "Expected ppsAfterHarvest > initial");

        console.log("Panic");
        vm.prank(strategy.keeper());
        strategy.panic();

        console.log("Unpause");
        vm.prank(strategy.keeper());
        strategy.unpause();

        console.log("Deposit");
        user.approve(vault.want(), address(vault), wantAmount);
        user.depositAll(vault);

        console.log("Withdrawal");
        user.withdrawAll(vault);
        uint userBal = IERC20Like(vault.want()).balanceOf(address(user));
        console.log("User balance after withdrawal", userBal);
        assertGt(userBal, wantAmount * 99 / 100, "Expected balance increase");
    }

    function test_printCalls() public view {
        bytes memory callData = abi.encodeCall(IVault.proposeStrat, (address(strategy)));
        console.log("owner:", vault.owner());

        console.log("\nPropose:");
        console.log("target:", address(vault));
        console.log("data:", Utils.bytesToStr(callData));

        console.log("\nUpgrade:");
        callData = abi.encodeCall(IVault.upgradeStrat, ());
        console.log("target:", address(vault));
        console.log("data:", Utils.bytesToStr(callData));
    }
}