const { expect } = require("chai");
const { ethers } = require("hardhat");
const { tokens, timeShift, getBlockTime } = require("../utils/utils");
const Wallet = require("ethereumjs-wallet");
const { BigNumber } = require("@ethersproject/bignumber");

const ONE_DAY = 86400;
const CLAIM_TIMEOUT = 86400; // must be >= 24h
const CLAIM_DAILY_LIMIT = tokens(50_000);
const INIT_SUPPLY = tokens(10_000_000_000);
const EVENT_CLAIMREQUESTED = "0xc9526a3e881ac1f0ac366545becae3075658fdfe4e3f823e8bbe0a075889c497";
const FIRST_REQUEST_ID = 0;
const FIRST_CLAIMREQUEST = tokens(60_000);
const ZERO = BigNumber.from(0);

async function deposite(delivery, wallet) {
  await delivery.connect(wallet).deposite(INIT_SUPPLY);
}

async function request(contract, wallet, amount, must_be_request_id, sig_wallet, sig_wallet_private_key) {
  let nextNonce = await contract.connect(wallet).getWalletNonce();
  nextNonce++;
  let hash = await web3.utils.soliditySha3(wallet.address, amount, nextNonce, contract.address);
  let SigObject = await web3.eth.accounts.sign(hash, sig_wallet_private_key);
  let SigWallet_recovered = await web3.eth.accounts.recover(SigObject);
  expect(SigWallet_recovered.toUpperCase()).to.be.equal(sig_wallet.toUpperCase());
  let reqTx = await contract.connect(wallet).request(wallet.address, amount, nextNonce, SigObject.signature);
  let eReq = (await reqTx.wait()).events.filter((x) => {
    return x.topics[0] == EVENT_CLAIMREQUESTED;
  });
  expect(eReq[0].args.wallet).to.be.equal(wallet.address);
  expect(must_be_request_id).to.be.equal(eReq[0].args.reauestId);
}

async function passOneDay() {
  await timeShift((await getBlockTime(ethers)) + ONE_DAY);
}

describe("emidelivery", function () {
  let esw, EmiDelivery, SigWallet, SigWallet_PrivateKey;
  before(async () => {
    [deployer, owner, Alice, Bob, Clarc] = await ethers.getSigners();
    const wallet = Wallet.generate();
    SigWallet = wallet.getAddressString();
    SigWallet_PrivateKey = wallet.getPrivateKeyString();
  });

  this.beforeEach(async () => {
    const MOCKESW = await ethers.getContractFactory("MockESW");
    esw = await MOCKESW.deploy(INIT_SUPPLY);
    await esw.deployed();

    EMIDELIVERY = await ethers.getContractFactory("emidelivery");
    EmiDelivery = await upgrades.deployProxy(EMIDELIVERY, [
      SigWallet,
      esw.address,
      owner.address,
      CLAIM_TIMEOUT,
      CLAIM_DAILY_LIMIT,
    ]);

    await EmiDelivery.deployed();

    await esw.transfer(owner.address, await esw.balanceOf(deployer.address));
    await esw.connect(owner).approve(EmiDelivery.address, await esw.balanceOf(owner.address));
  });

  it("owner deposite/withdraw", async function () {
    await deposite(EmiDelivery, owner);
    expect(await esw.balanceOf(EmiDelivery.address)).to.be.equal(INIT_SUPPLY);

    await EmiDelivery.connect(owner).withdraw(INIT_SUPPLY);
    expect(await esw.balanceOf(owner.address)).to.be.equal(INIT_SUPPLY);
  });

  it("make request", async function () {
    await deposite(EmiDelivery, owner);

    expect(await EmiDelivery.totalSupply()).to.be.equal(INIT_SUPPLY);
    expect(await EmiDelivery.claimDailyLimit()).to.be.equal(CLAIM_DAILY_LIMIT);

    await request(EmiDelivery, Alice, FIRST_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    let AvailableToClaim = await EmiDelivery.connect(Alice).getAvailableToClaim();
    expect(AvailableToClaim.available).to.be.equal(0); // request timeout not passed

    // pass claim timeout
    await passOneDay();

    AvailableToClaim = await EmiDelivery.connect(Alice).getAvailableToClaim();

    expect(AvailableToClaim.available).to.be.equal(CLAIM_DAILY_LIMIT); // request is greater, so maximum is daily limit
    expect(AvailableToClaim.requestIds[0]).to.be.equal(FIRST_REQUEST_ID);
    expect(await EmiDelivery.lockedForRequests()).to.be.equal(FIRST_CLAIMREQUEST);

    expect(await EmiDelivery.totalSupply()).to.be.equal(INIT_SUPPLY);
    expect(await EmiDelivery.availableForRequests()).to.be.equal(BigNumber.from(INIT_SUPPLY).sub(FIRST_CLAIMREQUEST));
  });

  it("request with insufficient reserves", async function () {
    await expect(
      request(EmiDelivery, Alice, FIRST_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey)
    ).to.be.revertedWith("insufficient reserves");
  });
  it("request and claim with sufficient reserves", async function () {
    await deposite(EmiDelivery, owner);
    await request(EmiDelivery, Alice, FIRST_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(0);

    // try to claim before timeout passed
    await expect(EmiDelivery.connect(Alice).claim()).to.be.revertedWith("nothing to claim");

    // pass claim timeout
    await passOneDay();

    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(CLAIM_DAILY_LIMIT);
    await EmiDelivery.connect(Alice).claim();
    expect(await esw.balanceOf(Alice.address)).to.be.equal(CLAIM_DAILY_LIMIT);

    // rest of requests (Alice)
    expect(await EmiDelivery.lockedForRequests()).to.be.equal(
      BigNumber.from(FIRST_CLAIMREQUEST).sub(BigNumber.from(CLAIM_DAILY_LIMIT))
    );

    expect((await EmiDelivery.connect(Alice).getRemainderOfRequests()).remainder).to.be.equal(
      BigNumber.from(FIRST_CLAIMREQUEST).sub(BigNumber.from(CLAIM_DAILY_LIMIT))
    );

    // available 0
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(ZERO);

    // pass claim timeout
    await passOneDay();

    // available 10_000
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(
      BigNumber.from(FIRST_CLAIMREQUEST).sub(BigNumber.from(CLAIM_DAILY_LIMIT))
    );

    await EmiDelivery.connect(Alice).claim();

    // Alice got 60_000 and request completed
    expect(await esw.balanceOf(Alice.address)).to.be.equal(FIRST_CLAIMREQUEST);
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(ZERO);
    expect((await EmiDelivery.connect(Alice).getRemainderOfRequests()).remainder).to.be.equal(ZERO);

    let requestInfo = await EmiDelivery.requests((await EmiDelivery.getFinishedRequests(Alice.address))[0]);
    expect(requestInfo.requestedAmount).to.be.equal(requestInfo.paidAmount);
  });
});
