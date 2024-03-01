// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./PrfctVaultV7.sol";
import "@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol";

// PerfectSwap Vault V7 Proxy Factory
// Minimal proxy pattern for creating new PerfectSwap vaults
contract PrfctVaultV7Factory {
  using ClonesUpgradeable for address;

  // Contract template for deploying proxied PerfectSwap vaults
  PrfctVaultV7 public instance;

  event ProxyCreated(address proxy);

  // Initializes the Factory with an instance of the PerfectSwap Vault V7
  constructor(address _instance) {
    if (_instance == address(0)) {
      instance = new PrfctVaultV7();
    } else {
      instance = PrfctVaultV7(_instance);
    }
  }

  // Creates a new PerfectSwap Vault V7 as a proxy of the template instance
  // A reference to the new proxied PerfectSwap Vault V7
  function cloneVault() external returns (PrfctVaultV7) {
    return PrfctVaultV7(cloneContract(address(instance)));
  }

  // Deploys and returns the address of a clone that mimics the behaviour of `implementation`
  function cloneContract(address implementation) public returns (address) {
    address proxy = implementation.clone();
    emit ProxyCreated(proxy);
    return proxy;
  }
}