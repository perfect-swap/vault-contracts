const hardhat = require("hardhat");
const { getImplementationAddress } = require("@openzeppelin/upgrades-core");
const { addressBook } = require("blockchain-addressbook");

const { ethers, upgrades } = hardhat;

const chain = "avax";
const a = addressBook[chain].platforms.prfctfinance.prfctFeeRecipient;

const config = {
  impl: "VeJoeStaker",
  proxy: "0x8330C83583829074BA6FF96b4A6377966D80edbf",
};

async function main() {
  await hardhat.run("compile");

  const newImpl = await ethers.getContractFactory(config.impl);
  const upgraded = await upgrades.upgradeProxy(config.proxy, newImpl);

  console.log("Upgrade", upgraded.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
