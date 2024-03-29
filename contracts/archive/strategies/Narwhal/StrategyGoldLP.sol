// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/narwhal/INarwhalswapRouter.sol";
import "../../interfaces/narwhal/INarwhalswapPair.sol";
import "../../interfaces/narwhal/IGoldFarm.sol";

/**
 * @dev Implementation of a strategy to get yields from farming LP Pools in NarwhalSwap.
 * 
 * This strat is currently compatible with all Gold LP pools.
 */
contract StrategyGoldLP is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {gold} - Token generated by staking our funds. In this case it's the {gold} token.
     * {prfct} - PerfectSwap token, used to send funds to the treasury.
     * {lpPair} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {lpToken0, lpToken1} - Tokens that the strategy maximizes. INarwhalswapPair tokens
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public gold = address(0x8f4087Cb09E0F378f4278a314C94A636665dE24b);
    address constant public prfct = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    address public lpPair;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {unirouter} - Selected unirouter configured through constructor
     * {goldFarm} - GoldFarm contract
     * {poolId} - GoldFarm pool id
     */
    address public unirouter;
    address constant public goldFarm = address(0x77C10A04B7d3adEBE4F235D69b5c1f20Cbfd2E57);
    uint8 public poolId;

    /**
     * @dev Prfct Contracts:
     * {rewards} - Reward pool where the strategy fee earnings will go.
     * {treasury} - Address of the PerfectSwap treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     */
    address constant public rewards  = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address constant public treasury = address(0x4A32De8c248533C28904b24B4cFCFE18E9F2ad01);
    address public vault;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 4.5% for fees.
     *
     * {REWARDS_FEE} - 3% goes to PRFCT holders through the {rewards} pool.
     * {CALL_FEE} - 1% goes to whoever executes the harvest function as gas subsidy.
     * {TREASURY_FEE} - 0.5% goes to the treasury.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public REWARDS_FEE  = 665;
    uint constant public CALL_FEE     = 223;
    uint constant public TREASURY_FEE = 112;
    uint constant public MAX_FEE      = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using Thugswap.
     * {goldToWbnbRoute} - Route we take to get from {gold} into {wbnb}.
     * {wbnbToPrfctRoute} - Route we take to get from {wbnb} into {prfct}.
     * {goldToLp0Route} - Route we take to get from {gold} into {lpToken0}.
     * {goldToLp1Route} - Route we take to get from {gold} into {lpToken1}.
     */
    address[] public goldToWbnbRoute = [gold, wbnb];
    address[] public wbnbToPrfctRoute = [wbnb, prfct];
    address[] public goldToLp0Route;
    address[] public goldToLp1Route;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _lpPair, uint8 _poolId, address _vault, address _unirouter) public {
        lpPair = _lpPair;
        lpToken0 = INarwhalswapPair(lpPair).token0();
        lpToken1 = INarwhalswapPair(lpPair).token1();
        poolId = _poolId;
        vault = _vault;
        unirouter = _unirouter;

        if (lpToken0 == wbnb) {
            goldToLp0Route = [gold, wbnb];
        } else if (lpToken0 != gold) {
            goldToLp0Route = [gold, wbnb, lpToken0];
        }

        if (lpToken1 == wbnb) {
            goldToLp1Route = [gold, wbnb];
        } else if (lpToken1 != gold) {
            goldToLp1Route = [gold, wbnb, lpToken1];
        }

        IERC20(lpPair).safeApprove(goldFarm, uint(-1));
        IERC20(gold).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {lpPair} in the GoldFarm to farm {gold}
     */
    function deposit() public whenNotPaused {
        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal > 0) {
            IGoldFarm(goldFarm).deposit(poolId, pairBal);
        }
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {lpPair} from the GoldFarm.
     * The available {lpPair} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal < _amount) {   
            IGoldFarm(goldFarm).withdraw(poolId, _amount.sub(pairBal));
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
     * 1. It claims rewards from the GoldFarm.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {gold} token for {lpToken0} & {lpToken1}
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IGoldFarm(goldFarm).deposit(poolId, 0);
        chargeFees();
        addLiquidity();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards. 
     * 1% -> Call Fee
     * 0.5% -> Treasury fee
     * 3% -> PRFCT Holders
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(gold).balanceOf(address(this)).mul(45).div(1000);
        INarwhalswapRouter(unirouter).swapExactTokensForTokens(toWbnb, 0, goldToWbnbRoute, address(this), now.add(600));
        
        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);

        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        INarwhalswapRouter(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToPrfctRoute, treasury, now.add(600));

        uint256 rewardsFee = wbnbBal.mul(REWARDS_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFee);
    }

    /**
     * @dev Swaps {gold} for {lpToken0}, {lpToken1} & {wbnb} using ThugSwap.
     */
    function addLiquidity() internal { 
        uint256 goldHalf = IERC20(gold).balanceOf(address(this)).div(2);

        if (lpToken0 != gold) {
            INarwhalswapRouter(unirouter).swapExactTokensForTokens(goldHalf, 0, goldToLp0Route, address(this), now.add(600));
        }

        if (lpToken1 != gold) {
            INarwhalswapRouter(unirouter).swapExactTokensForTokens(goldHalf, 0, goldToLp1Route, address(this), now.add(600));
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        INarwhalswapRouter(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now.add(600));
    }

    /**
     * @dev Function to calculate the total underlaying {lpPair} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the GoldFarm.
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
     * @dev It calculates how much {lpPair} the strategy has allocated in the GoldFarm
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IGoldFarm(goldFarm).userInfo(poolId, address(this));
        return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the 
     * vault, ready to be migrated to the new strat.
     */ 
    function retireStrat() external onlyOwner {
        panic();

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));
        IERC20(lpPair).transfer(vault, pairBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the GoldFarm, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IGoldFarm(goldFarm).emergencyWithdraw(poolId);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(lpPair).safeApprove(goldFarm, 0);
        IERC20(gold).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(lpPair).safeApprove(goldFarm, uint(-1));
        IERC20(gold).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint(-1));
    }
}
