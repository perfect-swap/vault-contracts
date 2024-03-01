// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/common/IUniswapRouter.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/common/IRewardPool.sol";

/**
 * @dev Strategy to farm PNG through a Synthetix based rewards pool contract.
 */
contract StrategyPangolinLP is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wavax} - Required for liquidity routing when doing swaps.
     * {png} - Token generated by staking our funds. In this case it's the png token.
     * {lpPair} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {lpToken0, lpToken1} - Tokens that the strategy maximizes. IUniswapV2Pair tokens
     */
    address constant public wavax = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    address constant public png = address(0x60781C2586D68229fde47564546784ab3fACA982);
    address public lpPair;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {pngrouter} - Pangolin router
     * {rewardPool} - Reward Pool contract
     */
    address constant public pngrouter = address(0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106);
    address public rewardPool;

    /**
     * @dev Prfct Contracts:
     * {treasury} - Address of the Prfct treasury. Rewards accumulate here and are then sent to BSC.
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     */
    address constant public treasury = address(0xA3e3Af161943CfB3941B631676134bb048739727);
    address public vault;
    address public strategist;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 4.5% for fees.
     *
     * {TREASURY_FEE} - 3.75% goes to PRFCT holders through the {treasury}.
     * {CALL_FEE} - 0.25% goes to whoever executes the harvest function as gas subsidy.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public CALL_FEE       = 55;
    uint constant public TREASURY_FEE   = 833;
    uint constant public STRATEGIST_FEE = 112;
    uint constant public MAX_FEE        = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using Pangolin.
     * {pngToWavaxRoute} - Route we take to get from {png} into {wbnb}.
     * {pngToLp0Route} - Route we take to get from {png} into {lpToken0}.
     * {pngToLp1Route} - Route we take to get from {png} into {lpToken1}.
     */
    address[] public pngToWavaxRoute = [png, wavax];
    address[] public pngToLp0Route;
    address[] public pngToLp1Route;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _lpPair, address _rewardPool, address _vault, address _strategist) public {
        lpPair = _lpPair;
        lpToken0 = IUniswapV2Pair(lpPair).token0();
        lpToken1 = IUniswapV2Pair(lpPair).token1();
        rewardPool = _rewardPool;
        vault = _vault;
        strategist = _strategist;

        if (lpToken0 == wavax) {
            pngToLp0Route = [png, wavax];
        } else if (lpToken0 != png) {
            pngToLp0Route = [png, wavax, lpToken0];
        }

        if (lpToken1 == wavax) {
            pngToLp1Route = [png, wavax];
        } else if (lpToken1 != png) {
            pngToLp1Route = [png, wavax, lpToken1];
        }

        IERC20(lpPair).safeApprove(rewardPool, uint(-1));
        IERC20(png).safeApprove(pngrouter, uint(-1));
        IERC20(wavax).safeApprove(pngrouter, uint(-1));

        IERC20(lpToken0).safeApprove(pngrouter, 0);
        IERC20(lpToken0).safeApprove(pngrouter, uint(-1));

        IERC20(lpToken1).safeApprove(pngrouter, 0);
        IERC20(lpToken1).safeApprove(pngrouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {lpPair} in the Reward Pool to farm {png}
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

        uint256 withdrawalFee = pairBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
        IERC20(lpPair).safeTransfer(vault, pairBal.sub(withdrawalFee));
    
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the Reward Pool.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {png} token for {lpToken0} & {lpToken1}
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function harvest() external whenNotPaused {
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
        uint256 toWavax = IERC20(png).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouter(pngrouter).swapExactTokensForTokens(toWavax, 0, pngToWavaxRoute, address(this), now.add(600));

        uint256 wavaxBal = IERC20(wavax).balanceOf(address(this));

        uint256 treasuryFee = wavaxBal.mul(TREASURY_FEE).div(MAX_FEE);
        IERC20(wavax).safeTransfer(treasury, treasuryFee);

        uint256 callFee = wavaxBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wavax).safeTransfer(tx.origin, callFee);

        uint256 strategistFee = wavaxBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wavax).safeTransfer(strategist, strategistFee);

    }
    
    /**
     * @dev Swaps {png} for {lpToken0}, {lpToken1} & {wavax} using Pangolin.
     */
    function addLiquidity() internal {
        uint256 pngHalf = IERC20(png).balanceOf(address(this)).div(2);

        if (lpToken0 != png) {
            IUniswapRouter(pngrouter).swapExactTokensForTokens(pngHalf, 0, pngToLp0Route, address(this), now.add(600));
        }

        if (lpToken1 != png) {
            IUniswapRouter(pngrouter).swapExactTokensForTokens(pngHalf, 0, pngToLp1Route, address(this), now.add(600));
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouter(pngrouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now.add(600));
    }

    /**
     * @dev Function to calculate the total underlaying {lpPair} held by the strat.
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
        IERC20(png).safeApprove(pngrouter, 0);
        IERC20(wavax).safeApprove(pngrouter, 0);
        IERC20(lpToken0).safeApprove(pngrouter, 0);
        IERC20(lpToken1).safeApprove(pngrouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(lpPair).safeApprove(rewardPool, uint(-1));
        IERC20(png).safeApprove(pngrouter, uint(-1));
        IERC20(wavax).safeApprove(pngrouter, uint(-1));

        IERC20(lpToken0).safeApprove(pngrouter, 0);
        IERC20(lpToken0).safeApprove(pngrouter, uint(-1));

        IERC20(lpToken1).safeApprove(pngrouter, 0);
        IERC20(lpToken1).safeApprove(pngrouter, uint(-1));
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
