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
import "../../interfaces/nyanswop/IStakingRewards.sol";

/**
 * @dev Implementation of a strategy to get yields from farming LP Pools in Nyanswop.
 * Nyanswop is an automated market maker (“AMM”) that allows two tokens to be exchanged on the Binance Smart Chain.
 * It is fast, cheap, and allows anyone to participate. Nyanswop is aiming to be the #1 liquidity provider on BSC.
 *
 * This strategy simply deposits whatever funds it receives from the vault into the selected IStakingRewards pool.
 * NYA rewards from providing liquidity are farmed every few minutes, sold and split 50/50.
 * The corresponding pair of assets are bought and more liquidity is added to the IStakingRewards pool.
 *
 * This strat is currently compatible with all LP pools.
 */
contract StrategyNyanswopLP is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {nya} - Required for liquidity routing when doing swaps.
     * {prfct} - PerfectSwap token, used to send funds to the treasury.
     * {lpPair} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {lpToken0, lpToken1} - Tokens that the strategy maximizes. IUniswapV2Pair tokens
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public nya = address(0xbFa0841F7a90c4CE6643f651756EE340991F99D5);
    address constant public prfct = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    address public lpPair;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {nyanswopRouter} - Nyanswop unirouter
     * {pancakeswapRouter} - Nyanswop unirouter
     * {stakingRewards} - IStakingRewards contract
     */
    address constant public nyanswopRouter  = address(0xc946764369623F560a5962D32c1D16D45F1BD6fa);
    address constant public pancakeswapRouter  = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address public stakingRewards;

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
     * {CALL_FEE} - -.5% goes to whoever executes the harvest function as gas subsidy.
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
     * @dev Routes we take to swap tokens using Nyanswop.
     * {nyaToWbnbRoute} - Route we take to get from {nya} into {wbnb}. (nyanswop)
     * {wbnbToPrfctRoute} - Route we take to get from {usdt} into {prfct}. (pancakeswap)
     * {nyaToLp0Route} - Route we take to get from {nya} into {lpToken0}. (nyanswop)
     * {nyaToLp1Route} - Route we take to get from {nya} into {lpToken1}.  (nyanswop)
     */
    address[] public nyaToWbnbRoute = [nya, wbnb];
    address[] public wbnbToPrfctRoute = [wbnb, prfct];
    address[] public nyaToLp0Route;
    address[] public nyaToLp1Route;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _lpPair, address _stakingRewards, address _vault, address _strategist) public {
        lpPair = _lpPair;
        lpToken0 = IUniswapV2Pair(lpPair).token0();
        lpToken1 = IUniswapV2Pair(lpPair).token1();
        stakingRewards = _stakingRewards;
        vault = _vault;
        strategist = _strategist;

        if (lpToken0 == wbnb) {
            nyaToLp0Route = [nya, wbnb];
        } else if (lpToken0 != nya) {
            nyaToLp0Route = [nya, wbnb, lpToken0];
        }

        if (lpToken1 == wbnb) {
            nyaToLp1Route = [nya, wbnb];
        } else if (lpToken1 != nya) {
            nyaToLp1Route = [nya, wbnb, lpToken1];
        }

        IERC20(lpPair).safeApprove(stakingRewards, uint(-1));
        IERC20(nya).safeApprove(nyanswopRouter, uint(-1));
        IERC20(wbnb).safeApprove(pancakeswapRouter, uint(-1));

        IERC20(lpToken0).safeApprove(nyanswopRouter, 0);
        IERC20(lpToken0).safeApprove(nyanswopRouter, uint(-1));

        IERC20(lpToken1).safeApprove(nyanswopRouter, 0);
        IERC20(lpToken1).safeApprove(nyanswopRouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {lpPair} in the stakingRewards to farm {nya}
     */
    function deposit() public whenNotPaused {
        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal > 0) {
            IStakingRewards(stakingRewards).stake(pairBal);
        }
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {lpPair} from the IStakingRewards.
     * The available {lpPair} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal < _amount) {
            IStakingRewards(stakingRewards).withdraw(_amount.sub(pairBal));
            pairBal = IERC20(lpPair).balanceOf(address(this));
        }

        if (pairBal > _amount) {
            pairBal = _amount;
        }

        uint256 withdrawalFee = pairBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
        IERC20(lpPair).safeTransfer(vault, pairBal.sub(withdrawalFee));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the IStakingRewards.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {nya} token for {lpToken0} & {lpToken1}
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IStakingRewards(stakingRewards).getReward();
        chargeFees();
        addLiquidity();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards.
     * Sells {nya} to {wbnb} at Nyanswop, buys {prfct} with {wbnb} at Pancakeswap
     * 0.5% -> Call Fee
     * 0.5% -> Treasury fee
     * 0.5% -> Strategist fee
     * 3.0% -> PRFCT Holders
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(nya).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouter(nyanswopRouter).swapExactTokensForTokens(toWbnb, 0, nyaToWbnbRoute, address(this), now.add(600));

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);

        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        IUniswapRouter(pancakeswapRouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToPrfctRoute, treasury, now.add(600));

        uint256 rewardsFee = wbnbBal.mul(REWARDS_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFee);

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Swaps {nya} for {lpToken0}, {lpToken1} & {usdt} using Nyanswop.
     */
    function addLiquidity() internal {
        uint256 nyaHalf = IERC20(nya).balanceOf(address(this)).div(2);

        if (lpToken0 != nya) {
            IUniswapRouter(nyanswopRouter).swapExactTokensForTokens(nyaHalf, 0, nyaToLp0Route, address(this), now.add(600));
        }

        if (lpToken1 != nya) {
            IUniswapRouter(nyanswopRouter).swapExactTokensForTokens(nyaHalf, 0, nyaToLp1Route, address(this), now.add(600));
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouter(nyanswopRouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now.add(600));
    }

    /**
     * @dev Function to calculate the total underlaying {lpPair} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the ILPTokenPool.
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
     * @dev It calculates how much {lpPair} the strategy has allocated in the IStakingRewards
     */
    function balanceOfPool() public view returns (uint256) {
        return IStakingRewards(stakingRewards).balanceOf(address(this));
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IStakingRewards(stakingRewards).exit();

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));
        IERC20(lpPair).transfer(vault, pairBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the IStakingRewards, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IStakingRewards(stakingRewards).withdraw(balanceOfPool());
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(lpPair).safeApprove(stakingRewards, 0);
        IERC20(nya).safeApprove(nyanswopRouter, 0);
        IERC20(wbnb).safeApprove(pancakeswapRouter, 0);
        IERC20(lpToken0).safeApprove(nyanswopRouter, 0);
        IERC20(lpToken1).safeApprove(nyanswopRouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(lpPair).safeApprove(stakingRewards, uint(-1));
        IERC20(nya).safeApprove(nyanswopRouter, uint(-1));
        IERC20(wbnb).safeApprove(pancakeswapRouter, uint(-1));

        IERC20(lpToken0).safeApprove(nyanswopRouter, 0);
        IERC20(lpToken0).safeApprove(nyanswopRouter, uint(-1));

        IERC20(lpToken1).safeApprove(nyanswopRouter, 0);
        IERC20(lpToken1).safeApprove(nyanswopRouter, uint(-1));
    }
}
