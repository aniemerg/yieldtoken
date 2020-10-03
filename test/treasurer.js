const Treasurer = artifacts.require("./Treasurer");
const YToken = artifacts.require("./yToken");
const MockContract = artifacts.require("./MockContract");
const Oracle = artifacts.require("./Oracle");
const ERC20 = artifacts.require("ERC20");

const truffleAssert = require("truffle-assertions");
const helper = require("ganache-time-traveler");
const {timestamp} = require("./../src/utilities");
var OracleMock = null;
const SECONDS_IN_DAY = 86400;

contract("Treasurer", async accounts => {
  const collateralRatio = web3.utils.toWei("1.5");
  const minCollateralRatio = web3.utils.toWei("1.05");
  let TreasurerInstance;
  let collateralToken;
  let erc20;
  beforeEach("deploy OracleMock", async () => {
    erc20 = await ERC20.new();
    collateralToken = await MockContract.new();
    await collateralToken.givenAnyReturnBool(true);
    TreasurerInstance = await Treasurer.new(
      collateralToken.address,
      collateralRatio,
      minCollateralRatio
    );
    OracleMock = await MockContract.new();
    await TreasurerInstance.setOracle(OracleMock.address);
  });

  it("should refuse to issue a new yToken with old maturity date", async () => {
    var number = await web3.eth.getBlockNumber();
    var currentTimeStamp = (await web3.eth.getBlock(number)).timestamp;
    currentTimeStamp = currentTimeStamp - 1;
    await truffleAssert.fails(
      TreasurerInstance.createNewYToken(currentTimeStamp),
      truffleAssert.REVERT
    );
    //let series = await TreasurerInstance.createNewYToken(currentTimeStamp);
  });

  it("should issue a new yToken", async () => {
    var number = await web3.eth.getBlockNumber();
    var currentTimeStamp = (await web3.eth.getBlock(number)).timestamp;
    var era = currentTimeStamp + SECONDS_IN_DAY;
    let series = await TreasurerInstance.createNewYToken.call(era.toString());
    await TreasurerInstance.createNewYToken(era.toString());
    let address = await TreasurerInstance.yTokens(series);
    var yTokenInstance = await YToken.at(address);
    assert.equal(
      await yTokenInstance.maturityTime(),
      era,
      "New yToken has incorrect era"
    );
  });

  it("should accept collateral", async () => {
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1"), {
      from: accounts[1]
    });
    var result = await TreasurerInstance.unlocked(accounts[1]);
    assert.equal(
      result.toString(),
      web3.utils.toWei("1"),
      "Did not accept collateral"
    );
  });

  it("should return collateral", async () => {
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1"), {
      from: accounts[1]
    });
    await TreasurerInstance.withdrawCollateral(web3.utils.toWei("1"), {
      from: accounts[1]
    });
    const transferFunctionality = erc20.contract.methods
      .transfer(accounts[1], web3.utils.toWei("1"))
      .encodeABI();
    assert.equal(
      1,
      await collateralToken.invocationCountForCalldata.call(
        transferFunctionality
      )
    );
  });

  it("should provide Oracle address", async () => {
    const _address = await TreasurerInstance.oracle();
    assert.equal(_address, OracleMock.address);
  });

  it("should issueYToken new yTokens", async () => {
    // create another yToken series with a 24 hour period until maturity
    var number = await web3.eth.getBlockNumber();
    var currentTimeStamp = (await web3.eth.getBlock(number)).timestamp;
    var series = 0;
    var era = currentTimeStamp + SECONDS_IN_DAY;
    await TreasurerInstance.createNewYToken(era);
    //funding
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1"), {
      from: accounts[1]
    });
    // set up oracle
    const oracle = await Oracle.new();
    var rate = web3.utils.toWei(".01"); // rate = Dai/ETH
    await OracleMock.givenAnyReturnUint(rate); // should price ETH at $100 * ONE

    // issueYToken new yTokens
    await TreasurerInstance.issueYToken(
      series,
      web3.utils.toWei("1"),
      web3.utils.toWei("1"),
      {from: accounts[1]}
    );

    // check yToken balance
    const token = await TreasurerInstance.yTokens.call(series);
    const yTokenInstance = await YToken.at(token);
    const balance = await yTokenInstance.balanceOf(accounts[1]);
    assert.equal(
      balance.toString(),
      web3.utils.toWei("1"),
      "Did not issueYToken new yTokens"
    );

    //check unlocked collateral, lockedCollateralAmount collateral
    const repo = await TreasurerInstance.repos(series, accounts[1]);
    assert.equal(
      repo.lockedCollateralAmount.toString(),
      web3.utils.toWei("1"),
      "Did not lock collateral"
    );
    assert.equal(
      repo.debtAmount.toString(),
      web3.utils.toWei("1"),
      "Did not create debtAmount"
    );
  });

  it("should accept tokens to wipe yToken debt", async () => {
    var amountToWipe = web3.utils.toWei(".1");
    var currentTimeStamp = await timestamp("latest", web3);
    var series = 0;
    var era = currentTimeStamp + SECONDS_IN_DAY;
    await TreasurerInstance.createNewYToken(era);

    //funding
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1"), {
      from: accounts[1]
    });

    // set up oracle
    const oracle = await Oracle.new();
    var rate = web3.utils.toWei(".01"); // rate = Dai/ETH
    await OracleMock.givenAnyReturnUint(rate); // should price ETH at $100 * ONE

    // issueYToken new yTokens
    await TreasurerInstance.issueYToken(
      series,
      web3.utils.toWei("1"),
      web3.utils.toWei("1"),
      {from: accounts[1]}
    );

    // get acess to token
    const token = await TreasurerInstance.yTokens.call(series);
    const yTokenInstance = await YToken.at(token);

    //authorize the wipe
    await yTokenInstance.approve(TreasurerInstance.address, amountToWipe, {
      from: accounts[1]
    });
    // wipe tokens
    await TreasurerInstance.wipe(series, amountToWipe, web3.utils.toWei(".1"), {
      from: accounts[1]
    });

    // check yToken balance
    const balance = await yTokenInstance.balanceOf(accounts[1]);
    assert.equal(
      balance.toString(),
      web3.utils.toWei(".9"),
      "Did not wipe yTokens"
    );

    //check unlocked collateral, lockedCollateralAmount collateral
    const repo = await TreasurerInstance.repos(series, accounts[1]);
    assert.equal(
      repo.lockedCollateralAmount.toString(),
      web3.utils.toWei(".9"),
      "Did not unlock collateral"
    );
    assert.equal(
      repo.debtAmount.toString(),
      web3.utils.toWei(".9"),
      "Did not wipe debg"
    );
  });

  it("should refuse to create an undercollateralized repos", async () => {
    var series = 0;

    // set up oracle
    const oracle = await Oracle.new();
    var rate = web3.utils.toWei(".01"); // rate = Dai/ETH
    await OracleMock.givenAnyReturnUint(rate); // should price ETH at $100 * ONE

    // issueYToken new yTokens with new account
    // at 100 dai/ETH, and 150% collateral requirement (set at deployment),
    // should refuse to create 101 yTokens
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1.5"), {
      from: accounts[2]
    });
    await truffleAssert.fails(
      TreasurerInstance.issueYToken(
        series,
        web3.utils.toWei("101"),
        web3.utils.toWei("1.5"),
        {from: accounts[2]}
      ),
      truffleAssert.REVERT
    );
  });

  it("should accept liquidations undercollateralized repos", async () => {
    var series = 0;
    var era = (await timestamp("latest", web3)) + SECONDS_IN_DAY;
    await TreasurerInstance.createNewYToken(era);

    // set up oracle
    const oracle = await Oracle.new();
    var rate = web3.utils.toWei(".01"); // rate = Dai/ETH
    await OracleMock.givenAnyReturnUint(rate); // should price ETH at $100 * ONE

    //fund account
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1.5"), {
      from: accounts[2]
    });
    // issueYToken new yTokens with new account
    await TreasurerInstance.issueYToken(
      series,
      web3.utils.toWei("100"),
      web3.utils.toWei("1.5"),
      {from: accounts[2]}
    );

    // transfer tokens to another account
    const token = await TreasurerInstance.yTokens.call(series);
    const yTokenInstance = await YToken.at(token);
    await yTokenInstance.transfer(accounts[3], web3.utils.toWei("100"), {
      from: accounts[2]
    });

    //change rate to issueYToken tokens undercollateralized
    rate = web3.utils.toWei(".02"); // rate = Dai/ETH
    await OracleMock.givenAnyReturnUint(rate);
    await truffleAssert.fails(
      TreasurerInstance.wipe(
        series,
        web3.utils.toWei("100"),
        web3.utils.toWei("0"),
        {from: accounts[2]}
      ),
      truffleAssert.REVERT,
      "treasurer-wipe-insufficient-token-balance"
    );

    // attempt to liquidate
    const result = await TreasurerInstance.liquidate(
      series,
      accounts[2],
      web3.utils.toWei("50"),
      {from: accounts[3]}
    );

    //check received 1.05
    const transferFunctionality = erc20.contract.methods
      .transfer(accounts[3], web3.utils.toWei("1.05"))
      .encodeABI();
    assert.equal(
      1,
      await collateralToken.invocationCountForCalldata.call(
        transferFunctionality
      )
    );

    //check unlocked collateral, lockedCollateralAmount collateral
    const repo = await TreasurerInstance.repos(series, accounts[2]);
    assert.equal(
      repo.lockedCollateralAmount.toString(),
      web3.utils.toWei(".45"),
      "Did not unlock collateral"
    );
    assert.equal(
      repo.debtAmount.toString(),
      web3.utils.toWei("50"),
      "Did not wipe debg"
    );
  });

  it("should allow for settlement", async () => {
    var series = 0;
    var era = (await timestamp("latest", web3)) + SECONDS_IN_DAY;
    await TreasurerInstance.createNewYToken(era);

    // set up oracle
    const oracle = await Oracle.new();
    var rate = web3.utils.toWei(".01"); // rate = Dai/ETH
    await OracleMock.givenAnyReturnUint(rate); // should price ETH at $100 * ONE

    //fund account
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1.5"), {
      from: accounts[2]
    });
    // issueYToken new yTokens with new account
    await TreasurerInstance.issueYToken(
      series,
      web3.utils.toWei("100"),
      web3.utils.toWei("1.5"),
      {from: accounts[2]}
    );

    await helper.advanceTimeAndBlock(SECONDS_IN_DAY * 1.5);
    await TreasurerInstance.settlement(series);
    var rate = (await TreasurerInstance.settled(series)).toString();
    assert.equal(rate, web3.utils.toWei(".01"), "settled rate not set");
  });

  it("should allow token holder to withdraw face value", async () => {
    var series = 0;
    var era = (await timestamp("latest", web3)) + SECONDS_IN_DAY;
    await TreasurerInstance.createNewYToken(era);

    // set up oracle
    const oracle = await Oracle.new();
    var rate = web3.utils.toWei(".01"); // rate = Dai/ETH
    await OracleMock.givenAnyReturnUint(rate); // should price ETH at $100 * ONE

    //fund account
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1.5"), {
      from: accounts[2]
    });
    // issueYToken new yTokens with new account
    await TreasurerInstance.issueYToken(
      series,
      web3.utils.toWei("100"),
      web3.utils.toWei("1.5"),
      {from: accounts[2]}
    );
    await helper.advanceTimeAndBlock(SECONDS_IN_DAY * 1.5);
    await TreasurerInstance.settlement(series);
    var balance_before = await web3.eth.getBalance(accounts[2]);

    const result = await TreasurerInstance.withdraw(
      series,
      web3.utils.toWei("25"),
      {from: accounts[2]}
    );

    const transferFunctionality = erc20.contract.methods
      .transfer(accounts[2], web3.utils.toWei("0.25"))
      .encodeABI();
    assert.equal(
      1,
      await collateralToken.invocationCountForCalldata.call(
        transferFunctionality
      )
    );
  });

  it("should allow repo holder to close repo and receive remaining collateral", async () => {
    var series = 0;
    var era = (await timestamp("latest", web3)) + SECONDS_IN_DAY;
    await TreasurerInstance.createNewYToken(era);

    // set up oracle
    const oracle = await Oracle.new();
    var rate = web3.utils.toWei(".01"); // rate = Dai/ETH
    await OracleMock.givenAnyReturnUint(rate); // should price ETH at $100 * ONE

    //fund account
    await TreasurerInstance.topUpCollateral(web3.utils.toWei("1.5"), {
      from: accounts[2]
    });
    // issueYToken new yTokens with new account
    await TreasurerInstance.issueYToken(
      series,
      web3.utils.toWei("100"),
      web3.utils.toWei("1.5"),
      {from: accounts[2]}
    );
    await helper.advanceTimeAndBlock(SECONDS_IN_DAY * 1.5);
    await TreasurerInstance.settlement(series);
    var balance_before = await web3.eth.getBalance(accounts[2]);

    //run close
    await TreasurerInstance.close(series, {from: accounts[2]});

    const transferFunctionality = erc20.contract.methods
      .transfer(accounts[2], web3.utils.toWei("0.5"))
      .encodeABI();
    assert.equal(
      1,
      await collateralToken.invocationCountForCalldata.call(
        transferFunctionality
      )
    );
  });
});
