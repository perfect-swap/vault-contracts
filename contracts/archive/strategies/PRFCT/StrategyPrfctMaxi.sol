// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/common/IWBNB.sol";
import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IRewardPool.sol";

/**
 * @dev PRFCT MAXIMALIST STRATEGY. DEPOSIT PRFCT. USE THE BNB REWARDS TO GET MORE PRFCT!
 */
contract StrategyPrfctMaxi is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - The token that rewards are paid in.
     * {prfct} - PerfectSwap token. The token this strategy looks to maximize.
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public prfct = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);

    /**
     * @dev Third Party Contracts:
     * {unirouter} - Streetswap router to use as AMM.
     */
    address constant public unirouter = address(0x3bc677674df90A9e5D741f28f6CA303357D0E4Ec);

    /**
     * @dev Prfct Contracts:
     * {rewards} - Reward pool where the {prfct} is staked.
     * {vault} - Address of the vault that controls the strategy's funds.
     */
    address constant public rewards  = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address public vault;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on chargeFees().
     * Current implementation separates 1% total for fees.
     *
     * {REWARDS_FEE} - 0.5% goes to PRFCT holders through the {rewards} pool.
     * {CALL_FEE} - 0.5% goes to pay for harvest execution.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     * 
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 5 === 0.05% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public REWARDS_FEE  = 5;
    uint constant public CALL_FEE     = 5;
    uint constant public MAX_FEE      = 1000;

    uint constant public WITHDRAWAL_FEE = 5;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using Thugswap.
     * {wbnbToPrfctRoute} - Route we take to get from {wbnb} into {prfct}.
     */
    address[] public wbnbToPrfctRoute = [wbnb, prfct];
  
    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _vault) public {
        vault = _vault;

        IERC20(wbnb).safeApprove(unirouter, uint(-1));
        IERC20(prfct).safeApprove(rewards, uint(-1));
    }
    
    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It stakes the received {prfct} into the {rewards} pool.
     */
    function deposit() public whenNotPaused {
        uint256 prfctBal = IERC20(prfct).balanceOf(address(this));

        if (prfctBal > 0) {
            IRewardPool(rewards).stake(prfctBal);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {prfct} from the {rewards} pool.
     * The available {prfct} minus a withdrawal fee is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 prfctBal = IERC20(prfct).balanceOf(address(this));

        if (prfctBal < _amount) {   
            IRewardPool(rewards).withdraw(_amount.sub(prfctBal));
            prfctBal = IERC20(prfct).balanceOf(address(this));
        }

        if (prfctBal > _amount) {
            prfctBal = _amount;    
        }
        
        uint256 withdrawalFee = prfctBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
        IERC20(prfct).safeTransfer(vault, prfctBal.sub(withdrawalFee));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the RewardPool.
     * 2. It charges a small system fee.
     * 3. It swaps the {wbnb} token for more {prfct}
     * 4. It deposits the {prfct} back into the pool.
     */
    function harvest() external whenNotPaused onlyOwner {
        require(!Address.isContract(msg.sender), "!contract");
        IRewardPool(rewards).getReward();
        chargeFees();
        swapRewards();
        deposit();
    }

    /**
     * @dev Takes out 1% as system fees from the rewards. 
     * 0.5% -> Call Fee
     * 0.5% -> Rewards fee
     */
    function chargeFees() internal {
        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(tx.origin, callFee);

        uint256 rewardsFee = wbnbBal.mul(REWARDS_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFee);
    }

    /**
     * @dev Swaps whatever {wbnb} it has for more {prfct}.
     */
    function swapRewards() internal {
        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(wbnbBal, 0, wbnbToPrfctRoute, address(this), now.add(600));
    }

    /**
     * @dev Function to calculate the total underlaying {prfct} held by the strat.
     * It takes into account both the funds at hand, as the funds allocated in the RewardsPool.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfPrfct().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {prfct} the contract holds.
     */
    function balanceOfPrfct() public view returns (uint256) {
        return IERC20(prfct).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {prfct} the strategy has allocated in the RewardsPool
     */
    function balanceOfPool() public view returns (uint256) {
        return IRewardPool(rewards).balanceOf(address(this));
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the 
     * vault, ready to be migrated to the new strat.
     */ 
    function retireStrat() external onlyOwner {
        panic();

        uint256 prfctBal = IERC20(prfct).balanceOf(address(this));
        IERC20(prfct).transfer(vault, prfctBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the OriginalGangster, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IRewardPool(rewards).withdraw(balanceOfPool());
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(wbnb).safeApprove(unirouter, 0);
        IERC20(prfct).safeApprove(rewards, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(wbnb).safeApprove(unirouter, uint(-1));
        IERC20(prfct).safeApprove(rewards, uint(-1));
    }
}
