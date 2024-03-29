// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/fortube/IFor.sol";
import "../../interfaces/fortube/IFToken.sol";
import "../../interfaces/fortube/IBankController.sol";
import "../../interfaces/fortube/IForReward.sol";

/**
 @dev Implementation of a strategy to get yields from farming the FOR token. 
 Fortube is a lending platform that incentivizes lenders by distributing their governance token.
 The strategy simply deposits whatever funds it receives from the vault into Fortube. Rewards 
 generated in FOR can regularly be harvested, swapped for the original vault asset, and deposited 
 again for compound faming.
 This strat is currently compatible with: USDT, FOR, BUSD, ETH, BNB, BTCB, LTC, BCH, XRP, DOT, EOS, LINK, ONT, 
 XTZ and DAI. The token to use is configured with a constructor argument.
 */ 

contract StrategyFortube {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /** 
     * @dev Tokens Used:
     * {output} - Token generated by staking our funds. In this case it's the FOR governance token. 
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {want} - Token that the strategy maximizes. The same token that users deposit in the vault. 
    */
    address constant public output = address(0x658A109C5900BC6d2357c87549B651670E5b0539);
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c); 
    address  public want; 

    /**
     * @dev Third Party Contracts:
     * {unirouter} - AMM used to swap from {output} into {want}
     * {fortube} - Fortube Bank contract. Main contract the strat interacts with.
     * {fortube_reward} - Fortube rewards pool. Used to claim rewards.
     */
    address  public unirouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address constant public fortube = address(0x0cEA0832e9cdBb5D476040D58Ea07ecfbeBB7672);
    address  public fortube_reward = address(0x55838F18e79cFd3EA22Eea08Bd3Ec18d67f314ed); 
    
    /**
     * @dev Prfct Contracts:
     * {rewards} - Reward pool where the strategy fee earnings will go.
     * {vault} - Address of the vault that controls the strategy's funds.
     */
    address public rewards = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C); 
    address public vault;

    /** 
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     Current implementation separates 5% for fees.
     * {fee} - 4% goes to PRFCT holders through the {rewards} pool.
     * {callfee} - 1% goes to whoever executes the harvest function as gas subsidy.
     * {withdrawalFee} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
    */
    uint public fee = 500; 
    uint public callfee = 500;
    uint constant public max = 1000;      

    uint public withdrawalFee = 10;
    uint constant public withdrawalMax = 10000;

    // Convenience value for UIs to display the strat name. It is initialized on contract deploy.
    string public getName;

    // Route we take to get from {output} into {want}. Required to execute swaps with Unswap clones.
    address[] public swap2TokenRouting;

    // Route we take to get from {output} into {wbnb}. Required to execute swaps with Unswap clones.
    address[] public swap2WbnbRouting;

    // Route we take to get from {want} into {wbnb}. Required to execute swaps with Unswap clones.
    address[] public want2WbnbRouting;

    /**
     * @dev Initializes the strategy with the token that it will look to maximize.
     */   
    constructor(address _want, address _vault) public {
        want = _want;
        vault = _vault;

        getName = string(
            abi.encodePacked("Prfct:Strategy:", 
                abi.encodePacked(ERC20(want).name(),"The Force Token"
                )
            ));
        swap2WbnbRouting = [output,wbnb];
        want2WbnbRouting = [want,wbnb];
        swap2TokenRouting = [output,wbnb,want];
        
        IERC20(want).safeApprove(unirouter, 0);
        IERC20(want).safeApprove(unirouter, uint(-1));
        
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(output).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work. It gets called whenever someone deposits 
     * in the strategy's vault contract. It provides whatever {want} it has available to be 
     * lent out on Fortube.
     */        
    function deposit() public {
        uint _want = IERC20(want).balanceOf(address(this));
        address _controller = IFor(fortube).controller();
        if (_want > 0) {
            IERC20(want).safeApprove(_controller, 0);
            IERC20(want).safeApprove(_controller, _want);
            IFor(fortube).deposit(want, _want);
        }
    }

    /**
     * @dev It withdraws funds from Fortube and sents them back to the vault.
     * Gets called when users withdraw from the parent vault.
     */    
    function withdraw(uint _amount) external {
        require(msg.sender == vault, "!vault");
        
        uint _balance = IERC20(want).balanceOf(address(this));
        if (_balance < _amount) {
            _amount = _withdrawSome(_amount.sub(_balance));
            _amount = _amount.add(_balance);
        }

        uint _fee = 0;
        if (withdrawalFee > 0){
            _fee = _amount.mul(withdrawalFee).div(withdrawalMax);
        }        
        
        IERC20(want).safeTransfer(vault, _amount.sub(_fee));
    }

    /**
     * @dev Internal function that manages the actual withdraw from the Fortube Bank.
     */ 
    function _withdrawSome(uint256 _amount) internal returns (uint) {
        IFor(fortube).withdrawUnderlying(want,_amount);
        return _amount;
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards. 
     * 1. It claims rewards from Fortube reward pool
     * 2. It swaps the FOR token for {want} 
     * 3. It charges the system fee and sends it to PRFCT stakers.
     * 4. It re-invests the remaining profits.
     */    
    function harvest() public {
        require(!Address.isContract(msg.sender),"!contract");
        IForReward(fortube_reward).claimReward();
        doswap();
        dosplit();
        deposit();
    }

    /**
     * @dev Swaps {output} for {want} using the established Uniswap clone.
     */
    function doswap() internal {
        uint256 _2token = IERC20(output).balanceOf(address(this)).mul(98).div(100);
        uint256 _2wbnb = IERC20(output).balanceOf(address(this)).mul(2).div(100);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(_2token, 0, swap2TokenRouting, address(this), now.add(600));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(_2wbnb, 0, swap2WbnbRouting, address(this), now.add(600));
        
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(_want, 0, want2WbnbRouting, address(this), now.add(600));
        }
    }

    /**
     * @dev Takes our 4% as system fees from the rewards. Takes out an extra 1% as 
     * gas subsidy and pays it out to the function caller.
     */
    function dosplit() internal {
        uint _bal = IERC20(wbnb).balanceOf(address(this));
        uint _fee = _bal.mul(fee).div(max);
        uint _callfee = _bal.mul(callfee).div(max);
        IERC20(wbnb).safeTransfer(rewards, _fee);
        IERC20(wbnb).safeTransfer(msg.sender, _callfee);
    }

    /**
     * @dev Function to calculate the total underlaying {want} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in Fortube.
     */
    function balanceOf() public view returns (uint) {
        return balanceOfWant()
               .add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {want} the contract holds.
     */    
    function balanceOfWant() public view returns (uint) {
        return IERC20(want).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {want} the strategy has allocated in Fortube.
     */    
    function balanceOfPool() public view returns (uint) {
        address _controller = IFor(fortube).controller();
        IFToken fToken = IFToken(IBankController(_controller).getFTokeAddress(want));
        return fToken.calcBalanceOfUnderlying(address(this));
    }
}