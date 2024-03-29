// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/mdex/IMasterChef.sol";

/**
 * @dev Implementation of a strategy to get yields from farming LP Pools in MDex.
 * This strategy simply deposits whatever funds it receives from the vault into the selected HECOPool pool.
 * MDX rewards from providing liquidity are farmed every few minutes, sold and split 50/50. 
 * The corresponding pair of assets are bought and more liquidity is added to the HECOPool pool.
 * 
 * This strat is currently compatible with all LP pools.
 */
contract StrategyMdexLP is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wht} - Required for liquidity routing when doing swaps.
     * {mdx} - Token generated by staking our funds. In this case it's the MDX token.
     * {lpPair} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {lpToken0, lpToken1} - Tokens that the strategy maximizes. IUniswapV2Pair tokens
     */
    address constant public wht = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public mdx = address(0x25D2e80cB6B86881Fd7e07dd263Fb79f4AbE033c);
    address public lpPair;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {unirouter} - MDex unirouter
     * {masterchef} - MDex MasterChef contract
     * {poolId} - MasterChef pool id
     */
    address constant public unirouter  = address(0xED7d5F38C79115ca12fe6C0041abb22F0A06C300);
    address constant public masterchef = address(0xFB03e11D93632D97a8981158A632Dd5986F5E909);
    uint8 public poolId;

    /**
     * @dev Prfct Contracts:
     * {treasury} - Address of the Prfct treasury. Rewards accumulate here and are then sent to BSC.
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     */
    address constant public treasury = address(0xf4859A3f36fBcA24BF8299bf56359fB441b03034);
    address public vault;
    address public strategist;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 4.5% for fees.
     *
     * {TREASURY_FEE} - 3.5% goes to PRFCT holders through the {treasury}.
     * {CALL_FEE} - 0.5% goes to whoever executes the harvest function as gas subsidy.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public CALL_FEE       = 111;
    uint constant public TREASURY_FEE   = 777;
    uint constant public STRATEGIST_FEE = 112;
    uint constant public MAX_FEE        = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using MDex.
     * {mdxToWhtRoute} - Route we take to get from {mdx} into {wht}.
     * {mdxToLp0Route} - Route we take to get from {mdx} into {lpToken0}.
     * {mdxToLp1Route} - Route we take to get from {mdx} into {lpToken1}.
     */
    address[] public mdxToWhtRoute = [mdx, wht];
    address[] public mdxToLp0Route;
    address[] public mdxToLp1Route;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

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

        if (lpToken0 == wht) {
            mdxToLp0Route = [mdx, wht];
        } else if (lpToken0 != mdx) {
            mdxToLp0Route = [mdx, wht, lpToken0];
        }

        if (lpToken1 == wht) {
            mdxToLp1Route = [mdx, wht];
        } else if (lpToken1 != mdx) {
            mdxToLp1Route = [mdx, wht, lpToken1];
        }

        IERC20(lpPair).safeApprove(masterchef, uint(-1));
        IERC20(mdx).safeApprove(unirouter, uint(-1));
        IERC20(wht).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {lpPair} in the MasterChef to farm {mdx}
     */
    function deposit() public whenNotPaused {
        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal > 0) {
            IMasterChef(masterchef).deposit(poolId, pairBal);
        }
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {lpPair} from the MasterChef.
     * The available {lpPair} minus fees is returned to the vault.
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

        uint256 withdrawalFee = pairBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
        IERC20(lpPair).safeTransfer(vault, pairBal.sub(withdrawalFee));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the MasterChef.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {mdx} token for {lpToken0} & {lpToken1}
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IMasterChef(masterchef).deposit(poolId, 0);
        chargeFees();
        addLiquidity();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards. 
     * 3.5% -> Prfct Treasury
     * 0.5% -> Call Fee
     * 0.5% -> Strategist fee
     */
    function chargeFees() internal {
        uint256 toWht = IERC20(mdx).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toWht, 0, mdxToWhtRoute, address(this), now.add(600));

        uint256 whtBal = IERC20(wht).balanceOf(address(this));

        uint256 treasuryFee = whtBal.mul(TREASURY_FEE).div(MAX_FEE);
        IERC20(wht).safeTransfer(treasury, treasuryFee);

        uint256 callFee = whtBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wht).safeTransfer(tx.origin, callFee);

        uint256 strategistFee = whtBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wht).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Swaps {mdx} for {lpToken0} and {lpToken1} using a Uniswap based {unirouter}.
     */
    function addLiquidity() internal {
        uint256 mdxHalf = IERC20(mdx).balanceOf(address(this)).div(2);

        if (lpToken0 != mdx) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(mdxHalf, 0, mdxToLp0Route, address(this), now.add(600));
        }

        if (lpToken1 != mdx) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(mdxHalf, 0, mdxToLp1Route, address(this), now.add(600));
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now.add(600));
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
     * @dev It calculates how much {lpPair} the strategy has allocated in the MasterChef
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, , ) = IMasterChef(masterchef).userInfo(poolId, address(this));
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
    function panic() public onlyOwner {
        pause();
        IMasterChef(masterchef).emergencyWithdraw(poolId);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(lpPair).safeApprove(masterchef, 0);
        IERC20(mdx).safeApprove(unirouter, 0);
        IERC20(wht).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(lpPair).safeApprove(masterchef, uint(-1));
        IERC20(mdx).safeApprove(unirouter, uint(-1));
        IERC20(wht).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint(-1));

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
