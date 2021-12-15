const { expect } = require("chai");
const { ethers } = require("hardhat");
const { tokens, timeShift, getBlockTime } = require("../utils/utils");
const Wallet = require("ethereumjs-wallet");
const { BigNumber } = require("@ethersproject/bignumber");

const ONE_DAY = 86400;
const CLAIM_DAYS = 1;
const CLAIM_TIMEOUT = CLAIM_DAYS * 24 * 60 * 60; // must be >= 24h
const CLAIM_DAILY_LIMIT = tokens(50_000);
const INIT_SUPPLY = tokens(10_000_000_000);
const EVENT_CLAIMREQUESTED = "0x71431efdffe03bc79c5607c1cf67764f4cf3e224fb5e5dfc04178260aa0b9322";
const FIRST_REQUEST_ID = 0;
const SECOND_REQUEST_ID = 1;
const THIRD_REQUEST_ID = 2;
const FOURTH_REQUEST_ID = 3;
const FIRST_CLAIMREQUEST = tokens(60_000);
const ONETOKEN_CLAIMREQUEST = tokens(1);
const SWITCH_ON_ONEREQUEST = true;
const SWITCH_OFF_ONEREQUEST = false;
const SHIFT_SECONDS = 1 * 24 * 60 * 60;
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
  expect(must_be_request_id).to.be.equal(eReq[0].args.requestId);
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
      SWITCH_ON_ONEREQUEST,
      0,
      true,
    ]);

    await EmiDelivery.deployed();

    await esw.transfer(owner.address, await esw.balanceOf(deployer.address));
    await esw.connect(owner).approve(EmiDelivery.address, await esw.balanceOf(owner.address));
  });

  it("check converstion YMD to datetime and reverse are correct", async function () {
    expect((await EmiDelivery.timestampToYMD(await EmiDelivery.YMDToTimestamp("20210229"))).toString()).to.be.equal(
      "20210301"
    );
    expect((await EmiDelivery.timestampToYMD(await EmiDelivery.YMDToTimestamp("20200229"))).toString()).to.be.equal(
      "20200229"
    );
    expect((await EmiDelivery.timestampToYMD(await EmiDelivery.YMDToTimestamp("20211231"))).toString()).to.be.equal(
      "20211231"
    );
    expect((await EmiDelivery.timestampToYMD(await EmiDelivery.YMDToTimestamp("20211232"))).toString()).to.be.equal(
      "20220101"
    );
  });

  it("get localTime(), getDatesStarts() in YMD view and same with shift dates", async function () {
    let TodayStart = (await EmiDelivery.getDatesStarts()).todayStart;
    let TomorrowStart = (await EmiDelivery.getDatesStarts()).tomorrowStart;
    let LocalTime = await EmiDelivery.localTime();

    expect(TodayStart).to.be.equal(LocalTime);

    // shift dates + 24h
    await EmiDelivery.connect(owner).setLocalTimeShift(BigNumber.from(SHIFT_SECONDS).toString(), true);

    let TodayStart_shifted = (await EmiDelivery.getDatesStarts()).todayStart;
    let TomorrowStart_shifted = (await EmiDelivery.getDatesStarts()).tomorrowStart;
    let LocalTime_shifted = await EmiDelivery.localTime();

    // add 1 second when shifting executes
    expect(LocalTime_shifted).to.be.equal(BigNumber.from(LocalTime).add(SHIFT_SECONDS).add(1));
    expect(TodayStart_shifted).to.be.equal(BigNumber.from(TodayStart).add(SHIFT_SECONDS).add(1));
    expect(TomorrowStart_shifted).to.be.equal(BigNumber.from(TomorrowStart).add(SHIFT_SECONDS).add(1));
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

    // get nearest request date
    let dayNow = new Date((await getBlockTime(ethers)) * 1000);
    let YMDNow = dayNow.getFullYear() * 10000 + (dayNow.getMonth() + 1) * 100 + dayNow.getDate();
    expect(
      (await EmiDelivery.connect(Alice).getRemainderOfRequests()).veryFirstRequestDate.sub(BigNumber.from(YMDNow))
    ).to.be.equal(CLAIM_DAYS);
    expect((await EmiDelivery.connect(Alice).getRemainderOfRequests()).remainderPreparedForClaim).to.be.equal(ZERO);

    // pass claim timeout
    await passOneDay();

    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(CLAIM_DAILY_LIMIT);
    expect((await EmiDelivery.connect(Alice).getRemainderOfRequests()).remainderPreparedForClaim).to.be.equal(
      FIRST_CLAIMREQUEST
    );

    await EmiDelivery.connect(Alice).claim();
    expect(await esw.balanceOf(Alice.address)).to.be.equal(CLAIM_DAILY_LIMIT);

    expect((await EmiDelivery.connect(Alice).getRemainderOfRequests()).remainderPreparedForClaim).to.be.equal(
      BigNumber.from(FIRST_CLAIMREQUEST).sub(BigNumber.from(CLAIM_DAILY_LIMIT))
    );

    // rest of requests (Alice)
    expect(await EmiDelivery.lockedForRequests()).to.be.equal(
      BigNumber.from(FIRST_CLAIMREQUEST).sub(BigNumber.from(CLAIM_DAILY_LIMIT))
    );

    expect((await EmiDelivery.connect(Alice).getRemainderOfRequests()).remainderTotal).to.be.equal(
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
    expect((await EmiDelivery.connect(Alice).getRemainderOfRequests()).remainderTotal).to.be.equal(ZERO);

    let requestInfo = await EmiDelivery.requests((await EmiDelivery.getFinishedRequests(Alice.address))[0]);
    expect(requestInfo.requestedAmount).to.be.equal(requestInfo.paidAmount);
  });
  it("request Alice and Bob and Clarc try to delete Alices and Bob requests with no operators rights", async function () {
    await deposite(EmiDelivery, owner);
    await request(EmiDelivery, Alice, FIRST_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, FIRST_CLAIMREQUEST, SECOND_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await expect(EmiDelivery.connect(Clarc).removeRequest([FIRST_REQUEST_ID, SECOND_REQUEST_ID])).to.be.revertedWith(
      "only actual operator allowed"
    );

    // Clarc become operator
    await EmiDelivery.connect(owner).setOperator(Clarc.address, true);
    // Successfully removed requests
    await EmiDelivery.connect(Clarc).removeRequest([FIRST_REQUEST_ID, SECOND_REQUEST_ID]);
  });
  it("request Alice and Bob and admin delete Alices request, Alice unfortunately claim and Bob claims succesfull", async function () {
    await deposite(EmiDelivery, owner);
    await request(EmiDelivery, Alice, FIRST_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, FIRST_CLAIMREQUEST, SECOND_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await EmiDelivery.connect(owner).removeRequest([FIRST_REQUEST_ID]);

    // pass claim timeout
    await passOneDay();

    // Alice have nothing to claim
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(ZERO);
    expect((await EmiDelivery.connect(Bob).getAvailableToClaim()).available).to.be.equal(CLAIM_DAILY_LIMIT);

    // Alice try to claim, but request was removed
    await expect(EmiDelivery.connect(Alice).claim()).to.be.revertedWith("nothing to claim");
  });
  it("request Alice and Bob and admin delete Alices and Bob requests, Alice and Bob unfortunately claim", async function () {
    await deposite(EmiDelivery, owner);
    await request(EmiDelivery, Alice, FIRST_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, FIRST_CLAIMREQUEST, SECOND_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await EmiDelivery.connect(owner).removeRequest([FIRST_REQUEST_ID, SECOND_REQUEST_ID]);

    // pass claim timeout
    await passOneDay();

    // Alice and Bob have nothing to claim
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(ZERO);
    expect((await EmiDelivery.connect(Bob).getAvailableToClaim()).available).to.be.equal(ZERO);

    // Alice and Bob try to claim, but requests was removed
    await expect(EmiDelivery.connect(Alice).claim()).to.be.revertedWith("nothing to claim");
    await expect(EmiDelivery.connect(Bob).claim()).to.be.revertedWith("nothing to claim");
  });
  it("request Alice and Bob and admin delete Alices and Bob requests, Alice and Bob unfortunately claim and try again successfully", async function () {
    await deposite(EmiDelivery, owner);
    await request(EmiDelivery, Alice, FIRST_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, FIRST_CLAIMREQUEST, SECOND_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await EmiDelivery.connect(owner).removeRequest([FIRST_REQUEST_ID, SECOND_REQUEST_ID]);

    // pass claim timeout
    await passOneDay();

    // Alice and Bob have nothing to claim
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(ZERO);
    expect((await EmiDelivery.connect(Bob).getAvailableToClaim()).available).to.be.equal(ZERO);

    // Alice and Bob try to claim, but requests was removed
    await expect(EmiDelivery.connect(Alice).claim()).to.be.revertedWith("nothing to claim");
    await expect(EmiDelivery.connect(Bob).claim()).to.be.revertedWith("nothing to claim");

    // Alice and Bob try again
    await request(EmiDelivery, Alice, FIRST_CLAIMREQUEST, THIRD_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, FIRST_CLAIMREQUEST, FOURTH_REQUEST_ID, SigWallet, SigWallet_PrivateKey);

    // pass claim timeout
    await passOneDay();

    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(CLAIM_DAILY_LIMIT);
    expect((await EmiDelivery.connect(Bob).getAvailableToClaim()).available).to.be.equal(CLAIM_DAILY_LIMIT);

    // Alice and Bob try to claim, but requests was removed
    await EmiDelivery.connect(Alice).claim();
    // Bob was late
    await expect(EmiDelivery.connect(Bob).claim()).to.be.revertedWith("nothing to claim");
  });
  it("Alice and Bob try to request twice and get error", async function () {
    await deposite(EmiDelivery, owner);
    await request(EmiDelivery, Alice, ONETOKEN_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, ONETOKEN_CLAIMREQUEST, SECOND_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await expect(
      request(EmiDelivery, Alice, ONETOKEN_CLAIMREQUEST, THIRD_REQUEST_ID, SigWallet, SigWallet_PrivateKey)
    ).to.be.revertedWith("unclaimed request exists");
    await expect(
      request(EmiDelivery, Bob, ONETOKEN_CLAIMREQUEST, FOURTH_REQUEST_ID, SigWallet, SigWallet_PrivateKey)
    ).to.be.revertedWith("unclaimed request exists");
  });
  it("Alice and Bob try to request twice and get error, fully claimed and request again successfully", async function () {
    await deposite(EmiDelivery, owner);
    await request(EmiDelivery, Alice, ONETOKEN_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, ONETOKEN_CLAIMREQUEST, SECOND_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await expect(
      request(EmiDelivery, Alice, ONETOKEN_CLAIMREQUEST, THIRD_REQUEST_ID, SigWallet, SigWallet_PrivateKey)
    ).to.be.revertedWith("unclaimed request exists");
    await expect(
      request(EmiDelivery, Bob, ONETOKEN_CLAIMREQUEST, FOURTH_REQUEST_ID, SigWallet, SigWallet_PrivateKey)
    ).to.be.revertedWith("unclaimed request exists");

    // pass claim timeout
    await passOneDay();

    // Alice and Bob try to claim, but requests was removed
    await EmiDelivery.connect(Alice).claim();
    await EmiDelivery.connect(Bob).claim();

    await request(EmiDelivery, Alice, ONETOKEN_CLAIMREQUEST, THIRD_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, ONETOKEN_CLAIMREQUEST, FOURTH_REQUEST_ID, SigWallet, SigWallet_PrivateKey);

    // all requested and the same time is unavailable to claim
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(ZERO);
    expect((await EmiDelivery.connect(Bob).getAvailableToClaim()).available).to.be.equal(ZERO);

    // pass claim timeout
    await passOneDay();

    // all requested are ready to claim
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(ONETOKEN_CLAIMREQUEST);
    expect((await EmiDelivery.connect(Bob).getAvailableToClaim()).available).to.be.equal(ONETOKEN_CLAIMREQUEST);
  });
  it("Alice and Bob try to request twice and get error, fully claimed and request again successfully", async function () {
    await deposite(EmiDelivery, owner);
    await request(EmiDelivery, Alice, ONETOKEN_CLAIMREQUEST, FIRST_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, ONETOKEN_CLAIMREQUEST, SECOND_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await expect(
      request(EmiDelivery, Alice, ONETOKEN_CLAIMREQUEST, THIRD_REQUEST_ID, SigWallet, SigWallet_PrivateKey)
    ).to.be.revertedWith("unclaimed request exists");
    await expect(
      request(EmiDelivery, Bob, ONETOKEN_CLAIMREQUEST, FOURTH_REQUEST_ID, SigWallet, SigWallet_PrivateKey)
    ).to.be.revertedWith("unclaimed request exists");

    // admin allows multiple requests
    await EmiDelivery.connect(owner).setisOneRequest(SWITCH_OFF_ONEREQUEST);

    // and now successfully requested again
    await request(EmiDelivery, Alice, ONETOKEN_CLAIMREQUEST, THIRD_REQUEST_ID, SigWallet, SigWallet_PrivateKey);
    await request(EmiDelivery, Bob, ONETOKEN_CLAIMREQUEST, FOURTH_REQUEST_ID, SigWallet, SigWallet_PrivateKey);

    // pass claim timeout
    await passOneDay();

    // all requested are available to claim
    expect((await EmiDelivery.connect(Alice).getAvailableToClaim()).available).to.be.equal(
      BigNumber.from(ONETOKEN_CLAIMREQUEST).add(BigNumber.from(ONETOKEN_CLAIMREQUEST))
    );
    expect((await EmiDelivery.connect(Bob).getAvailableToClaim()).available).to.be.equal(
      BigNumber.from(ONETOKEN_CLAIMREQUEST).add(BigNumber.from(ONETOKEN_CLAIMREQUEST))
    );

    // Alice and Bob try to claim, but requests was removed
    await EmiDelivery.connect(Alice).claim();
    await EmiDelivery.connect(Bob).claim();
  });
});
