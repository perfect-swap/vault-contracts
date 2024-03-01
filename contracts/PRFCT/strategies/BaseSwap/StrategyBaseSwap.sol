// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin-4/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-4/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/common/IWrappedNative.sol";
import "../../interfaces/baseswap/IBaseSwapNFT.sol";
import "../../interfaces/baseswap/IBaseSwapVesting.sol";
import "../Common/StrategyFeeManagerInitializable.sol";

contract StrategyBaseSwap is StrategyFeeManagerInitializable {
    using SafeERC20 for IERC20;

    // Tokens used
    address public native;
    address public output;
    address public want;
    address public lpToken0;
    address public lpToken1;
    address public escrowToken;

    // Third party contracts
    address public nft;
    uint256 public tokenId;

    bool public harvestOnDeposit;
    uint256 public lastHarvest;
    bool public vestingRewards;
    uint256 public vestingLength;
    uint256 public lastVestCall;
    uint256 public totalLocked;
    uint256 public duration;

    // Routes
    address[] public outputToNativeRoute;
    address[] public nativeToLp0Route;
    address[] public nativeToLp1Route;
    address[][] public rewardToNativeRoute;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event ChargedFees(uint256 callFees, uint256 prfctFees, uint256 strategistFees);

    function initialize(
        address _nft,
        address[] memory _outputToNativeRoute,
        address[] memory _nativeToLp0Route,
        address[] memory _nativeToLp1Route,
        CommonAddresses calldata _commonAddresses
    ) public initializer {
        __StratFeeManager_init(_commonAddresses);
        nft = _nft;
        (want, output, escrowToken,,,,,,,) = IBaseSwapNFT(nft).getPoolInfo();

        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        require(_outputToNativeRoute[0] == output, "outputToNativeRoute[0] != output");
        outputToNativeRoute = _outputToNativeRoute;

        // setup lp routing
        lpToken0 = IUniswapV2Pair(want).token0();
        require(_nativeToLp0Route[0] == native, "nativeToLp0Route[0] != native");
        require(_nativeToLp0Route[_nativeToLp0Route.length - 1] == lpToken0, "nativeToLp0Route[last] != lpToken0");
        nativeToLp0Route = _nativeToLp0Route;

        lpToken1 = IUniswapV2Pair(want).token1();
        require(_nativeToLp1Route[0] == native, "nativeToLp1Route[0] != native");
        require(_nativeToLp1Route[_nativeToLp1Route.length - 1] == lpToken1, "nativeToLp1Route[last] != lpToken1");
        nativeToLp1Route = _nativeToLp1Route;

        tokenId = type(uint).max;
        vestingRewards = true;
        vestingLength = 15 days;
        duration = 24 hours;

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            if (IBaseSwapNFT(nft).exists(tokenId)) {
                IBaseSwapNFT(nft).addToPosition(tokenId, wantBal);
            } else {
                IBaseSwapNFT(nft).createPosition(wantBal, 0);
                tokenId = IBaseSwapNFT(nft).lastTokenId();
            }
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IBaseSwapNFT(nft).withdrawFromPosition(tokenId, _amount - wantBal);
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal * withdrawalFee / WITHDRAWAL_MAX;
            wantBal = wantBal - withdrawalFeeAmount;
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external virtual override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IBaseSwapNFT(nft).harvestPosition(tokenId);
        if (vestingRewards) _vestRewards();
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            _convertRewards();
            chargeFees(callFeeRecipient);
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            totalLocked = wantHarvested + lockedProfit();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    function _vestRewards() internal {
        if (block.timestamp > lastVestCall + 1 days) {
            uint256 indexLength = IBaseSwapVesting(escrowToken).getUserRedeemsLength(address(this));
            if (indexLength > 0) {
                for (uint i; i < indexLength;) {
                    (,, uint256 endTime,,) = IBaseSwapVesting(escrowToken).getUserRedeem(address(this), i);
                    if (block.timestamp > endTime) {
                        IBaseSwapVesting(escrowToken).finalizeRedeem(i);
                        indexLength -= 1;
                    } else {
                        unchecked { ++i; }
                    }
                }
            }

            uint256 vestAmount = IERC20(escrowToken).balanceOf(address(this));
            if (vestAmount > 0) {
                IBaseSwapVesting(escrowToken).redeem(vestAmount, vestingLength);
            }
            
            lastVestCall = block.timestamp;
        }
    }

    function _convertRewards() internal {
        // unwrap any native
        uint256 nativeBal = address(this).balance;
        if (nativeBal > 0) {
            IWrappedNative(native).deposit{value: nativeBal}();
        }
        // convert any output to native
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(outputBal, 0, outputToNativeRoute, address(this), block.timestamp);

        // convert additional rewards
        if (rewardToNativeRoute.length != 0) {
            for (uint i; i < rewardToNativeRoute.length; i++) {
                uint256 toNative = IERC20(rewardToNativeRoute[i][0]).balanceOf(address(this));
                if (toNative > 0) {
                    IUniswapRouterETH(unirouter).swapExactTokensForTokens(toNative, 0, rewardToNativeRoute[i], address(this), block.timestamp);
                }
            }
        }
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        IOrigFeeConfig.FeeCategory memory fees = getFees();
        uint256 nativeBal = IERC20(native).balanceOf(address(this)) * fees.total / DIVISOR;

        uint256 callFeeAmount = nativeBal * fees.call / DIVISOR;
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 prfctFeeAmount = nativeBal * fees.prfct / DIVISOR;
        IERC20(native).safeTransfer(prfctFeeRecipient, prfctFeeAmount);

        uint256 strategistFeeAmount = nativeBal * fees.strategist / DIVISOR;
        IERC20(native).safeTransfer(strategist, strategistFeeAmount);

        emit ChargedFees(callFeeAmount, prfctFeeAmount, strategistFeeAmount);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 nativeHalf = IERC20(native).balanceOf(address(this)) / 2;
        if (lpToken0 != native) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                nativeHalf, 0, nativeToLp0Route, address(this), block.timestamp
            );
        }

        if (lpToken1 != native) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                nativeHalf, 0, nativeToLp1Route, address(this), block.timestamp
            );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(
            lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), block.timestamp
        );
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant() + balanceOfPool() - lockedProfit();
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 amount,,,,,,,,) = IBaseSwapNFT(nft).getStakingPosition(tokenId);
        return amount;
    }

    function lockedProfit() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastHarvest;
        uint256 remaining = elapsed < duration ? duration - elapsed : 0;
        return totalLocked * remaining / duration;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        (uint256 outputAmount,) = IBaseSwapNFT(nft).pendingRewards(tokenId);
        return outputAmount;
    }

    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        IOrigFeeConfig.FeeCategory memory fees = getFees();
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
        if (outputBal > 0) {
            uint256[] memory amountOut = IUniswapRouterETH(unirouter).getAmountsOut(outputBal, outputToNativeRoute);
            nativeOut = amountOut[amountOut.length -1];
        }

        return nativeOut * fees.total / DIVISOR * fees.call / DIVISOR;
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IBaseSwapNFT(nft).emergencyWithdraw(tokenId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IBaseSwapNFT(nft).emergencyWithdraw(tokenId);
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(nft, type(uint).max);
        IERC20(output).safeApprove(unirouter, type(uint).max);
        IERC20(native).safeApprove(unirouter, type(uint).max);

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, type(uint).max);

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, type(uint).max);

        if (rewardToNativeRoute.length != 0) {
            for (uint i; i < rewardToNativeRoute.length; i++) {
                IERC20(rewardToNativeRoute[i][0]).safeApprove(unirouter, 0);
                IERC20(rewardToNativeRoute[i][0]).safeApprove(unirouter, type(uint).max);
            }
        }
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(nft, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(native).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);

        if (rewardToNativeRoute.length != 0) {
            for (uint i; i < rewardToNativeRoute.length; i++) {
                IERC20(rewardToNativeRoute[i][0]).safeApprove(unirouter, 0);
            }
        }
    }

    function addRewardRoute(address[] memory _rewardToNativeRoute) external onlyOwner {
        IERC20(_rewardToNativeRoute[0]).safeApprove(unirouter, 0);
        IERC20(_rewardToNativeRoute[0]).safeApprove(unirouter, type(uint).max);
        rewardToNativeRoute.push(_rewardToNativeRoute);
    }

    function removeLastRewardRoute() external onlyManager {
        address reward = rewardToNativeRoute[rewardToNativeRoute.length - 1][0];
        if (reward != lpToken0 && reward != lpToken1) {
            IERC20(reward).safeApprove(unirouter, 0);
        }
        rewardToNativeRoute.pop();
    }

    function setVestingRewards(bool _vestingRewards, uint256 _vestingLength) external onlyManager {
        vestingRewards = _vestingRewards;
        vestingLength = _vestingLength;
    }

    function outputToNative() external view returns (address[] memory) {
        return outputToNativeRoute;
    }

    function nativeToLp0() external view returns (address[] memory) {
        return nativeToLp0Route;
    }

    function nativeToLp1() external view returns (address[] memory) {
        return nativeToLp1Route;
    }

    function rewardToNative() external view returns (address[][] memory) {
        return rewardToNativeRoute;
    }

    function onERC721Received(
        address,
        address,
        uint,
        bytes calldata
    ) external view returns (bytes4) {
        require(msg.sender == address(nft), "!nft");
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    function onNFTHarvest(
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256
    ) external view returns (bool) {
        require(msg.sender == address(nft), "!nft");
        return true;
    }

    function onNFTAddToPosition(address, uint256, uint256) external view returns (bool) {
        require(msg.sender == address(nft), "!nft");
        return true;
    }

    function onNFTWithdraw(address, uint256, uint256) external view returns (bool) {
        require(msg.sender == address(nft), "!nft");
        return true;
    }

    receive () external payable {}
}
