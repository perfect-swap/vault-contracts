// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../../node_modules/forge-std/src/Test.sol";
import "../../contracts/PRFCT/infra/PRFCT.sol";

contract PRFCTTest is Test {

    function test_mint() public {
        PRFCT prfct = new PRFCT(address(this));
        assertEq(prfct.totalSupply(), 80_000*1e18);
        assertEq(prfct.balanceOf(address(this)), 80_000*1e18);
    }

}