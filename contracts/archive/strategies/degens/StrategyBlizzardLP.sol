// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/common/IMasterChef.sol";
import "../../utils/GasThrottler.sol";

/**
 * @dev Implementation of a strategy to get yields from farming LP Pools in Blizzard.Money.
 *
 * This strat is currently compatible with all LP pools.
 */
contract StrategyBlizzardLP is Ownable, Pausable, GasThrottler {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb, busd} - Required for liquidity routing when doing swaps.
     * {output} - Token generated by staking our funds. In this case, xBLZD.
     * {prfct} - PerfectSwap token, used to send funds to the treasury.
     * {lpPair} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {lpToken0, lpToken1} - Tokens that the strategy maximizes. IUniswapV2Pair tokens
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    address constant public output = address(0x9a946c3Cb16c08334b69aE249690C236Ebd5583E);
    address constant public prfct = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    address public lpPair;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {unirouter} - PancakeSwap unirouter
     * {masterchef} - MasterChef contract
     * {poolId} - MasterChef pool id
     */
    address constant public unirouter  = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address constant public masterchef = address(0x367CdDA266ADa588d380C7B970244434e4Dde790);
    uint8 public poolId;

    /**
     * @dev Prfct Contracts:
     * {rewards} - Reward pool where the strategy fee earnings will go.
     * {treasury} - Address of the PerfectSwap treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     * {keeper} - Address used as an extra strat manager.
     */
    address constant public rewards  = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address constant public treasury = address(0x4A32De8c248533C28904b24B4cFCFE18E9F2ad01);
    address public vault;
    address public strategist;
    address public keeper;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 4.5% for fees.
     *
     * {TREASURY_FEE} - 0.5% goes to the treasury.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_CALL_FEE} - Max value that the {callFee} can be configured to.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     * {callFee} - 0.25% goes to whoever executes the harvest. Can be adjusted.
     * {rewardsFee} - 3.25% goes to PRFCT holders through the {rewards} pool. Adjusted by callFee changes.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public TREASURY_FEE   = 112;
    uint constant public STRATEGIST_FEE = 112;
    uint constant public MAX_CALL_FEE   = 111;
    uint constant public MAX_FEE        = 1000;
    uint public callFee                 = 56;
    uint public rewardsFee              = MAX_FEE - TREASURY_FEE - STRATEGIST_FEE - callFee;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using PancakeSwap.
     * {outputToWbnbRoute} - Route we take to get from {output} into {wbnb}.
     * {wbnbToPrfctRoute} - Route we take to get from {wbnb} into {prfct}.
     * {outputToLp0Route} - Route we take to get from {output} into {lpToken0}.
     * {outputToLp1Route} - Route we take to get from {output} into {lpToken1}.
     */
    address[] public outputToWbnbRoute = [output, wbnb];
    address[] public wbnbToPrfctRoute = [wbnb, prfct];
    address[] public outputToLp0Route;
    address[] public outputToLp1Route;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest();

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _lpPair, uint8 _poolId, address _vault, address _strategist) public {
        lpPair = _lpPair;
        lpToken0 = IUniswapV2Pair(lpPair).token0();
        lpToken1 = IUniswapV2Pair(lpPair).token1();
        poolId = _poolId;
        vault = _vault;
        strategist = _strategist;

        if (lpToken0 == wbnb) {
            outputToLp0Route = [output, wbnb];
        } else if (lpToken0 == busd) {
            outputToLp0Route = [output, busd];
        } else if (lpToken0 != output) {
            outputToLp0Route = [output, wbnb, lpToken0];
        }

        if (lpToken1 == wbnb) {
            outputToLp1Route = [output, wbnb];
        } else if (lpToken1 == busd) {
            outputToLp1Route = [output, busd];
        } else if (lpToken1 != output) {
            outputToLp1Route = [output, wbnb, lpToken1];
        }

        IERC20(lpPair).safeApprove(masterchef, uint(-1));
        IERC20(output).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {lpPair} in the MasterChef to farm {output}
     */
    function deposit() public whenNotPaused {
        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal > 0) {
            IMasterChef(masterchef).deposit(poolId, pairBal);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {lpPair} from the MasterChef.
     * The available {lpPair} minus fees is returned to the vault.
     * Fees are not assessed if the Vault is paused.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal < _amount) {
            IMasterChef(masterchef).withdraw(poolId, _amount.sub(pairBal));
            pairBal = IERC20(lpPair).balanceOf(address(this));
        }

        if (pairBal > _amount) {
            pairBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(lpPair).safeTransfer(vault, pairBal);
        } else {
            uint256 withdrawalFee = pairBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
            IERC20(lpPair).safeTransfer(vault, pairBal.sub(withdrawalFee));
        }
    }

    /**
     * @dev Public harvest. Doesn't work when the strat is paused.
     */
    function harvest() external whenNotPaused {
        _harvest();
    }

    /**
     * @dev Harvest to keep the strat working while paused. Helpful in some cases.
     */
    function sudoHarvest() external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        _harvest();
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the MasterChef.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {output} token for {lpToken0} & {lpToken1}
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function _harvest() internal gasThrottle {
        IMasterChef(masterchef).deposit(poolId, 0);
        chargeFees();
        addLiquidity();
        deposit();

        emit StratHarvest();
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards. 
     * 0.25% -> Call Fee
     * 0.5% -> Treasury fee
     * 0.5% -> Strategist fee
     * 3.25% -> PRFCT Holders
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(output).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toWbnb, 0, outputToWbnbRoute, address(this), now.add(600));

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFeeAmount = wbnbBal.mul(callFee).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFeeAmount);

        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToPrfctRoute, treasury, now.add(600));

        uint256 rewardsFeeAmount = wbnbBal.mul(rewardsFee).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFeeAmount);

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Swaps {output} for {lpToken0}, {lpToken1} & {wbnb} using PancakeSwap.
     */
    function addLiquidity() internal {
        uint256 outputHalf = IERC20(output).balanceOf(address(this)).div(2);

        if (lpToken0 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp0Route, address(this), now.add(600));
        }

        if (lpToken1 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputHalf, 0, outputToLp1Route, address(this), now.add(600));
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now.add(600));
    }

    /**
     * @dev Function to synchronize balance of {lpPair}.
     * Can be called by the vault before minting shares.
     * No-op as underlying contract doesn't need to be synced
     */
    function updateBalance() public {}

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
     * @dev It calculates how much {lpPair} the strategy has allocated in the MasterChef
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(poolId, address(this));
        return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the 
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(masterchef).emergencyWithdraw(poolId);

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));
        IERC20(lpPair).transfer(vault, pairBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the MasterChef, leaving rewards behind
     */
    function panic() public {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        pause();
        IMasterChef(masterchef).emergencyWithdraw(poolId);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        _pause();

        IERC20(lpPair).safeApprove(masterchef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        _unpause();

        IERC20(lpPair).safeApprove(masterchef, uint(-1));
        IERC20(output).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Updates address where strategist fee earnings will go.
     * @param _strategist new strategist address.
     */
    function setStrategist(address _strategist) external {
        require(msg.sender == strategist, "!strategist");
        strategist = _strategist;
    }

    /**
     * @dev Updates address of the strat keeper.
     * @param _keeper new keeper address.
     */
    function setKeeper(address _keeper) external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        keeper = _keeper;
    }

    /**
     * @dev Updates the harvest {callFee}. Capped by {MAX_CALL_FEE}.
     * @param _fee new fee to give harvesters.
     */
    function setCallFee(uint256 _fee) external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");
        require(_fee < MAX_CALL_FEE, "!cap");

        callFee = _fee;
        rewardsFee = MAX_FEE - TREASURY_FEE - STRATEGIST_FEE - callFee;
    }

    /**
     * @dev Rescues random funds stuck that the strat can't handle.
     * @param _token address of the token to rescue.
     */
    function inCaseTokensGetStuck(address _token) external {
        require(msg.sender == owner() || msg.sender == keeper, "!authorized");

        require(_token != output, "!output");
        require(_token != lpPair, "!lpPair");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }
}
