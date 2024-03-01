// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

import { stdJson } from "forge-std/StdJson.sol";
import { CommonBase } from "forge-std/Base.sol";

/**
 * Allow access to our shared addressbook inside solidity
 * 
 * Inherits:
 * - CommonBase to get access to the `vm` lib
 */
contract AddressBook is CommonBase {
    using stdJson for string;

    struct PrfctPlatform {
        address keeper;
        address strategyOwner;
        address vaultOwner;
    }

    mapping(string => PrfctPlatform) _prfctPlatformDataCache;

    // debug events
    event AddressBook_Info_ConfigRead(string config);
    event AddressBook_Debug_PrfctPlatformData(PrfctPlatform data);
    
    function getPrfctPlatformConfig(string memory chainName) public returns (PrfctPlatform memory) {
        // test if our cache contains the key
        if (_prfctPlatformDataCache[chainName].keeper == address(0)) {
            // use our custom hardhat task to print out the network config in json format
            string[] memory inputs = new string[](4);
            inputs[0] = "yarn";
            inputs[1] = "--silent";
            inputs[2] = "test-data:addressbook:prfct";
            inputs[3] = chainName;
            string memory jsonConfig = string(vm.ffi(inputs));
            require(bytes(jsonConfig).length > 0, "Could not read hardhat config");
            emit AddressBook_Info_ConfigRead(jsonConfig);

            // parse the json into an array of network config
            bytes memory data = jsonConfig.parseRaw("*");
            PrfctPlatform memory config = abi.decode(data, (PrfctPlatform));
        
            emit AddressBook_Debug_PrfctPlatformData(config);
            // move the array to storage, no simple way to do that atm
            _prfctPlatformDataCache[chainName] = config;
        }

        return _prfctPlatformDataCache[chainName];
    }
}