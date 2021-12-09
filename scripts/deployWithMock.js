const { ethers, network } = require("hardhat");
const hre = require("hardhat");
const { constants, Contract, Signer, utils } = require("ethers");
const { tokens, timeout, getBlockTime } = require("../utils/utils");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deployer wallet: ", deployer.address);
  console.log("Deployer balance:", (await deployer.getBalance()).toString());

  const SIGWALLET = process.env.SIGWALLET;
  const ESW_ADDRESS = process.env.ESW_ADDRESS;
  const INIT_SUPPLY = tokens(10_000_000);
  const CLAIM_TIMEOUT = 86400; // must be >= 24h
  const CLAIM_DAILY_LIMIT = tokens(50_000);
  const SWITCH_ON_ONEREQUEST = true;
  const CHAINID = await hre.network.provider.send("eth_chainId");

  // hardhat => 800
  // mumbai => 6000
  const TIME_OUT = CHAINID == 0x7a69 ? 800 : 6000;

  EMIDELIVERY = await ethers.getContractFactory("emidelivery");
  EmiDelivery = await upgrades.deployProxy(EMIDELIVERY, [
    SIGWALLET,
    ESW_ADDRESS,
    deployer.address,
    CLAIM_TIMEOUT,
    CLAIM_DAILY_LIMIT,
    SWITCH_ON_ONEREQUEST,
  ]);
  await timeout(TIME_OUT);

  await EmiDelivery.deployed();
  await timeout(TIME_OUT);
  console.log("EmiDelivery deployed to", EmiDelivery.address);

  EmiDelivery_Impl = await upgrades.erc1967.getImplementationAddress(EmiDelivery.address);

  //verification
  if (CHAINID != 0x7a69) {
    await hre.run("verify:verify", {
      address: EmiDelivery_Impl,
      constructorArguments: [],
    });
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
