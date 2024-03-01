// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPrfctVault {
    struct StratCandidate {
        address implementation;
        uint proposedTime;
    }
    function strategy() external view returns (address);
    function stratCandidate() external view returns (StratCandidate memory);
}
