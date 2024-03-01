// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin-4/contracts/token/ERC20/ERC20.sol";

contract PRFCT is ERC20 {

    constructor(address treasury) ERC20("Prfct", "PRFCT")  {
        _mint(treasury, 80_000 ether);
    }

}