// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/common/IUniswapRouter.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/common/IRewardPool.sol";
import "../../utils/GasThrottler.sol";

/**
 * @dev Strategy to farm HPS through a Synthetix based rewards pool contract.
 */
contract StrategyBillionHpsLP is Ownable, Pausable, GasThrottler {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {hps} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {prfct} - PerfectSwap token, used to send funds to the treasury.
     * {lpPair} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {lpToken0, lpToken1} - Tokens that the strategy maximizes. IUniswapV2Pair tokens
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public hps  = address(0xeDa21B525Ac789EaB1a08ef2404dd8505FfB973D);
    address constant public prfct = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    address constant public lpPair = address(0xcaC3b7DE7D5c44E8E1048241C7dE29a61b5C3E7d);
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {unirouter} - PancakeSwap unirouter
     * {julrouter} - JulSwap router
     * {rewardPool} - Reward Pool contract
     */
    address constant public unirouter  = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address constant public julrouter  = address(0xbd67d157502A23309Db761c41965600c2Ec788b2);
    address constant public rewardPool = address(0xcC16f9Ca629b140d46886A82FeaF586A5532BD99);

    /**
     * @dev Prfct Contracts:
     * {rewards} - Reward pool where the strategy fee earnings will go.
     * {treasury} - Address of the PerfectSwap treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     */
    address constant public rewards  = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address constant public treasury = address(0x4A32De8c248533C28904b24B4cFCFE18E9F2ad01);
    address public vault;
    address public strategist;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 4.5% for fees.
     *
     * {REWARDS_FEE} - 3% goes to PRFCT holders through the {rewards} pool.
     * {CALL_FEE} - 0.5% goes to whoever executes the harvest function as gas subsidy.
     * {TREASURY_FEE} - 0.5% goes to the treasury.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public REWARDS_FEE    = 665;
    uint constant public CALL_FEE       = 111;
    uint constant public TREASURY_FEE   = 112;
    uint constant public STRATEGIST_FEE = 112;
    uint constant public MAX_FEE        = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using PancakeSwap.
     * {hpsToWbnbRoute} - Route we take to get from {hps} into {wbnb}.
     * {wbnbToPrfctRoute} - Route we take to get from {wbnb} into {prfct}.
     * {hpsToLp0Route} - Route we take to get from {hps} into {lpToken0}.
     * {hpsToLp1Route} - Route we take to get from {hps} into {lpToken1}.
     */
    address[] public hpsToWbnbRoute = [hps, wbnb];
    address[] public wbnbToPrfctRoute = [wbnb, prfct];
    address[] public hpsToLp0Route;
    address[] public hpsToLp1Route;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _vault, address _strategist) public {
        lpToken0 = IUniswapV2Pair(lpPair).token0();
        lpToken1 = IUniswapV2Pair(lpPair).token1();
        vault = _vault;
        strategist = _strategist;

        if (lpToken0 == wbnb) {
            hpsToLp0Route = [hps, wbnb];
        } else if (lpToken0 != hps) {
            hpsToLp0Route = [hps, wbnb, lpToken0];
        }

        if (lpToken1 == wbnb) {
            hpsToLp1Route = [hps, wbnb];
        } else if (lpToken1 != hps) {
            hpsToLp1Route = [hps, wbnb, lpToken1];
        }

        IERC20(lpPair).safeApprove(rewardPool, uint(-1));
        IERC20(hps).safeApprove(julrouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(julrouter, 0);
        IERC20(lpToken0).safeApprove(julrouter, uint(-1));

        IERC20(lpToken1).safeApprove(julrouter, 0);
        IERC20(lpToken1).safeApprove(julrouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {lpPair} in the Reward Pool to farm {hps}
     */
    function deposit() public whenNotPaused {
        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal > 0) {
            IRewardPool(rewardPool).stake(pairBal);
        }
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {lpPair} from the Reward Pool.
     * The available {lpPair} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal < _amount) {
            IRewardPool(rewardPool).withdraw(_amount.sub(pairBal));
            pairBal = IERC20(lpPair).balanceOf(address(this));
        }

        if (pairBal > _amount) {
            pairBal = _amount;
        }

        if (tx.origin == owner()) {
            IERC20(lpPair).safeTransfer(vault, pairBal);
        } else {
            uint256 withdrawalFee = pairBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
            IERC20(lpPair).safeTransfer(vault, pairBal.sub(withdrawalFee));
        }
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the Reward Pool.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {hps} token for {lpToken0} & {lpToken1}
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function harvest() external whenNotPaused gasThrottle {
        require(!Address.isContract(msg.sender), "!contract");
        IRewardPool(rewardPool).getReward();
        chargeFees();
        addLiquidity();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards.
     * 0.5% -> Call Fee
     * 0.5% -> Treasury fee
     * 0.5% -> Strategist fee
     * 3.0% -> PRFCT Holders
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(hps).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouter(julrouter).swapExactTokensForTokens(toWbnb, 0, hpsToWbnbRoute, address(this), now.add(600));

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);

        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        IUniswapRouter(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToPrfctRoute, treasury, now.add(600));

        uint256 rewardsFee = wbnbBal.mul(REWARDS_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFee);

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Swaps {hps} for {lpToken0}, {lpToken1} & {wbnb} using JulSwap.
     */
    function addLiquidity() internal {
        uint256 hpsHalf = IERC20(hps).balanceOf(address(this)).div(2);

        if (lpToken0 != hps) {
            IUniswapRouter(julrouter).swapExactTokensForTokens(hpsHalf, 0, hpsToLp0Route, address(this), now.add(600));
        }

        if (lpToken1 != hps) {
            IUniswapRouter(julrouter).swapExactTokensForTokens(hpsHalf, 0, hpsToLp1Route, address(this), now.add(600));
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouter(julrouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now.add(600));
    }

    /**
     * @dev Function to calculate the total underlying {lpPair} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the MasterChef.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfLpPair().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {lpPair} the contract holds.
     */
    function balanceOfLpPair() public view returns (uint256) {
        return IERC20(lpPair).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {lpPair} the strategy has allocated in the Reward Pool
     */
    function balanceOfPool() public view returns (uint256) {
        return IRewardPool(rewardPool).balanceOf(address(this));
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IRewardPool(rewardPool).withdraw(balanceOfPool());

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));
        IERC20(lpPair).transfer(vault, pairBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the Reward Pool, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IRewardPool(rewardPool).withdraw(balanceOfPool());
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(lpPair).safeApprove(rewardPool, 0);
        IERC20(hps).safeApprove(julrouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(julrouter, 0);
        IERC20(lpToken1).safeApprove(julrouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(lpPair).safeApprove(rewardPool, uint(-1));
        IERC20(hps).safeApprove(julrouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(julrouter, 0);
        IERC20(lpToken0).safeApprove(julrouter, uint(-1));

        IERC20(lpToken1).safeApprove(julrouter, 0);
        IERC20(lpToken1).safeApprove(julrouter, uint(-1));

        deposit();
    }

    /**
     * @dev Updates address where strategist fee earnings will go.
     * @param _strategist new strategist address.
     */
    function setStrategist(address _strategist) external {
        require(msg.sender == strategist, "!strategist");
        strategist = _strategist;
    }
}