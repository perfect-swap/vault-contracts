import hardhat, { ethers, upgrades } from "hardhat";
import { verifyContract } from "../../utils/verifyContract";

const shouldVerifyOnEtherscan = true;

const contractNames = {
  PrfctFeeConfigurator: "PrfctFeeConfigurator",
};

const config = {
  keeper: "0x004b2Cf6888630ABebB2DaD39faAD738655e98C7",
  totalLimit: "95000000000000000",
}

const implementationConstructorArguments: any[] = []; // proxy implementations cannot have constructors

const deploy = async () => {
  const PrfctFeeConfiguratorFactory = await ethers.getContractFactory(contractNames.PrfctFeeConfigurator)

  console.log("Deploying:", contractNames.PrfctFeeConfigurator);

  const constructorArguments: any[] = [config.keeper, config.totalLimit];
  const transparentUpgradableProxy = await upgrades.deployProxy(PrfctFeeConfiguratorFactory, constructorArguments);
  await transparentUpgradableProxy.deployed();

  const implementationAddress = await upgrades.erc1967.getImplementationAddress(transparentUpgradableProxy.address);

  console.log();
  console.log("TransparentUpgradableProxy:", transparentUpgradableProxy.address);
  console.log(`Implementation address (${contractNames.PrfctFeeConfigurator}):`, implementationAddress);

  console.log();
  console.log("Running post deployment");

  const verifyContractsPromises: Promise<any>[] = [];
  if (shouldVerifyOnEtherscan) {
    console.log(`Verifying ${contractNames.PrfctFeeConfigurator}`);
    verifyContractsPromises.push(verifyContract(implementationAddress, implementationConstructorArguments));
  }
  console.log();

  await Promise.all(verifyContractsPromises);
};

deploy()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
