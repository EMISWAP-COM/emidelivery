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
  const CLAIM_TIMEOUT = 864000; // 10 × 24 × 60 × 60
  const CLAIM_DAILY_LIMIT = tokens(50_000);
  const SWITCH_ON_ONEREQUEST = false;
  const CHAINID = await hre.network.provider.send("eth_chainId");
  const LOCALSHIFT = 6;
  const POSITIVESHIFT = true;
  const OPERATOR = process.env.OPERATOR;
  const OWNER = process.env.OWNER;

  // hardhat => 800
  // mumbai => 20000
  const TIME_OUT = CHAINID == 0x7a69 ? 800 : 6000;

  EMIDELIVERY = await ethers.getContractFactory("emidelivery");
  EmiDelivery = await upgrades.deployProxy(EMIDELIVERY, [
    SIGWALLET,
    ESW_ADDRESS,
    deployer.address,
    CLAIM_TIMEOUT,
    CLAIM_DAILY_LIMIT,
    SWITCH_ON_ONEREQUEST,
    LOCALSHIFT,
    POSITIVESHIFT,
  ]);
  await timeout(TIME_OUT);

  await EmiDelivery.deployed();
  await timeout(TIME_OUT);
  console.log("EmiDelivery deployed to", EmiDelivery.address);
  
  EmiDelivery_Impl = await upgrades.erc1967.getImplementationAddress(EmiDelivery.address);

  await EmiDelivery.setOperator(OPERATOR, true);
  await timeout(TIME_OUT);

  await EmiDelivery.transferOwnership(OWNER);

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
