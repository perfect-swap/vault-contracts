// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin-4/contracts/access/Ownable.sol";
import "@openzeppelin-4/contracts/security/Pausable.sol";
import "../../interfaces/common/IOrigFeeConfig.sol";

contract StratFeeManager is Ownable, Pausable {

    struct CommonAddresses {
        address vault;
        address unirouter;
        address keeper;
        address strategist;
        address prfctFeeRecipient;
        address prfctFeeConfig;
    }

    // common addresses for the strategy
    address public vault;
    address public unirouter;
    address public keeper;
    address public strategist;
    address public prfctFeeRecipient;
    IOrigFeeConfig public prfctFeeConfig;

    uint256 constant DIVISOR = 1 ether;
    uint256 constant public WITHDRAWAL_FEE_CAP = 50;
    uint256 constant public WITHDRAWAL_MAX = 10000;
    uint256 internal withdrawalFee = 10;

    event SetStratFeeId(uint256 feeId);
    event SetWithdrawalFee(uint256 withdrawalFee);
    event SetVault(address vault);
    event SetUnirouter(address unirouter);
    event SetKeeper(address keeper);
    event SetStrategist(address strategist);
    event SetPrfctFeeRecipient(address prfctFeeRecipient);
    event SetPrfctFeeConfig(address prfctFeeConfig);

    constructor(
        CommonAddresses memory _commonAddresses
    ) {
        vault = _commonAddresses.vault;
        unirouter = _commonAddresses.unirouter;
        keeper = _commonAddresses.keeper;
        strategist = _commonAddresses.strategist;
        prfctFeeRecipient = _commonAddresses.prfctFeeRecipient;
        prfctFeeConfig = IOrigFeeConfig(_commonAddresses.prfctFeeConfig);
    }

    // checks that caller is either owner or keeper.
    modifier onlyManager() {
        _checkManager();
        _;
    }

    function _checkManager() internal view {
        require(msg.sender == owner() || msg.sender == keeper, "!manager");
    }

    // fetch fees from config contract
    function getFees() internal view returns (IOrigFeeConfig.FeeCategory memory) {
        return prfctFeeConfig.getFees(address(this));
    }

    // fetch fees from config contract and dynamic deposit/withdraw fees
    function getAllFees() external view returns (IOrigFeeConfig.AllFees memory) {
        return IOrigFeeConfig.AllFees(getFees(), depositFee(), withdrawFee());
    }

    function getStratFeeId() external view returns (uint256) {
        return prfctFeeConfig.stratFeeId(address(this));
    }

    function setStratFeeId(uint256 _feeId) external onlyManager {
        prfctFeeConfig.setStratFeeId(_feeId);
        emit SetStratFeeId(_feeId);
    }

    // adjust withdrawal fee
    function setWithdrawalFee(uint256 _fee) public onlyManager {
        require(_fee <= WITHDRAWAL_FEE_CAP, "!cap");
        withdrawalFee = _fee;
        emit SetWithdrawalFee(_fee);
    }

    // set new vault (only for strategy upgrades)
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
        emit SetVault(_vault);
    }

    // set new unirouter
    function setUnirouter(address _unirouter) external onlyOwner {
        unirouter = _unirouter;
        emit SetUnirouter(_unirouter);
    }

    // set new keeper to manage strat
    function setKeeper(address _keeper) external onlyManager {
        keeper = _keeper;
        emit SetKeeper(_keeper);
    }

    // set new strategist address to receive strat fees
    function setStrategist(address _strategist) external {
        require(msg.sender == strategist, "!strategist");
        strategist = _strategist;
        emit SetStrategist(_strategist);
    }

    // set new prfct fee address to receive prfct fees
    function setPrfctFeeRecipient(address _prfctFeeRecipient) external onlyOwner {
        prfctFeeRecipient = _prfctFeeRecipient;
        emit SetPrfctFeeRecipient(_prfctFeeRecipient);
    }

    // set new fee config address to fetch fees
    function setPrfctFeeConfig(address _prfctFeeConfig) external onlyOwner {
        prfctFeeConfig = IOrigFeeConfig(_prfctFeeConfig);
        emit SetPrfctFeeConfig(_prfctFeeConfig);
    }

    function depositFee() public virtual view returns (uint256) {
        return 0;
    }

    function withdrawFee() public virtual view returns (uint256) {
        return paused() ? 0 : withdrawalFee;
    }

    function beforeDeposit() external virtual {}
}