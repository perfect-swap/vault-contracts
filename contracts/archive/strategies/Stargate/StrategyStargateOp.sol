// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/common/IMasterChef.sol";
import "../../interfaces/stargate/IStargateRouter.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";
import "../../utils/StringUtils.sol";
import "../../utils/GasThrottler.sol";
import "../../utils/UniswapV3Utils.sol";

contract StrategyStargateOp is StratManager, FeeManager, GasThrottler {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct StratManagerParams {
        address keeper;
        address strategist;
        address unirouter;
        address vault;
        address prfctFeeRecipient;
    }

    // Tokens used
    address public native;
    address public output;
    address public want;
    address public depositToken;

    // Third party contracts
    address public chef;
    uint256 public poolId;
    address public stargateRouter;
    uint256 public routerPoolId;

    bool public harvestOnDeposit;
    uint256 public lastHarvest;
    string public pendingRewardsFunctionName;

    // Uniswap V3 paths
    bytes public outputToNativePath;
    bytes public outputToDepositPath;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event ChargedFees(uint256 callFees, uint256 prfctFees, uint256 strategistFees);

    constructor(
        address _want,
        uint256 _poolId,
        address _chef,
        uint256 _routerPoolId,
        address _stargateRouter,
        address[] memory _outputToNativeRoute,
        address[] memory _outputToDepositRoute,
        uint24[] memory _outputToNativeFee,
        uint24[] memory _outputToDepositFee,
        StratManagerParams memory _stratManager
    ) StratManager(_stratManager.keeper, _stratManager.strategist, _stratManager.unirouter, _stratManager.vault, _stratManager.prfctFeeRecipient) public {
        want = _want;
        poolId = _poolId;
        routerPoolId = _routerPoolId;
        chef = _chef;
        stargateRouter = _stargateRouter;

        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativePath = UniswapV3Utils.routeToPath(_outputToNativeRoute, _outputToNativeFee);

        require(_outputToDepositRoute[0] == output, '_outputToDeposit[0] != output');
        depositToken = _outputToDepositRoute[_outputToDepositRoute.length - 1];
        outputToDepositPath = UniswapV3Utils.routeToPath(_outputToDepositRoute, _outputToDepositFee);

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IMasterChef(chef).deposit(poolId, wantBal);
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IMasterChef(chef).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external gasThrottle virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external gasThrottle virtual {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IMasterChef(chef).deposit(poolId, 0);
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            chargeFees(callFeeRecipient);
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        uint256 toNative = IERC20(output).balanceOf(address(this)).mul(45).div(1000);
        UniswapV3Utils.swap(unirouter, outputToNativePath, toNative);

        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        uint256 callFeeAmount = nativeBal.mul(callFee).div(MAX_FEE);
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 prfctFeeAmount = nativeBal.mul(prfctFee).div(MAX_FEE);
        IERC20(native).safeTransfer(prfctFeeRecipient, prfctFeeAmount);

        uint256 strategistFeeAmount = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFeeAmount);

        emit ChargedFees(callFeeAmount, prfctFeeAmount, strategistFeeAmount);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        UniswapV3Utils.swap(unirouter, outputToDepositPath, outputBal);

        uint256 depositBal = IERC20(depositToken).balanceOf(address(this));
        IStargateRouter(stargateRouter).addLiquidity(routerPoolId, depositBal, address(this));
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount,) = IMasterChef(chef).userInfo(poolId, address(this));
        return _amount;
    }

    // change encoded path for swapping output to native
    function setNativePath(address[] memory _route, uint24[] memory _fee) external onlyOwner {
        require(_route[0] == output, '!output');
        require(_route[_route.length - 1] == native, '!native');
        outputToNativePath = UniswapV3Utils.routeToPath(_route, _fee);
    }

    // change encoded path for swapping output to deposit token
    function setDepositPath(address[] memory _route, uint24[] memory _fee) external onlyOwner {
        require(_route[0] == output, '!output');
        require(_route[_route.length - 1] == depositToken, '!deposit');
        outputToDepositPath = UniswapV3Utils.routeToPath(_route, _fee);
    }

    function setPendingRewardsFunctionName(string calldata _pendingRewardsFunctionName) external onlyManager {
        pendingRewardsFunctionName = _pendingRewardsFunctionName;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        string memory signature = StringUtils.concat(pendingRewardsFunctionName, "(uint256,address)");
        bytes memory result = Address.functionStaticCall(
            chef,
            abi.encodeWithSignature(
                signature,
                poolId,
                address(this)
            )
        );
        return abi.decode(result, (uint256));
    }

    // native reward amount for calling harvest
    // no "view" functions in Uniswap V3 to quote amounts
    function callReward() external pure returns (uint256) {
        return 0;
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    function setShouldGasThrottle(bool _shouldGasThrottle) external onlyManager {
        shouldGasThrottle = _shouldGasThrottle;
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(chef).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMasterChef(chef).emergencyWithdraw(poolId);
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
        IERC20(want).safeApprove(chef, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));
        IERC20(depositToken).safeApprove(stargateRouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(depositToken).safeApprove(stargateRouter, 0);
    }

    function outputToNative() external view returns (address[] memory) {
        return UniswapV3Utils.pathToRoute(outputToNativePath);
    }

    function outputToDeposit() external view returns (address[] memory) {
        return UniswapV3Utils.pathToRoute(outputToDepositPath);
    }
}
