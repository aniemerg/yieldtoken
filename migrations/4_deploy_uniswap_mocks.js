const UniswapFactoryMock = artifacts.require("UniswapFactoryMock");
const Treasurer = artifacts.require("Treasurer");
const Oracle = artifacts.require("Oracle");
const {timestamp} = require("../src/utilities");

setup = async web3 => {
  let treasurer = await Treasurer.deployed();
  let oracle = await Oracle.deployed();
  var rate = web3.utils.toWei(".01");
  await oracle.set(rate);
  await treasurer.setOracle(oracle.address);
  var maturityDate = (await timestamp("latest", web3)) + 24 * 60 * 60 * 30;
  await treasurer.createNewYToken(maturityDate.toString());
};

module.exports = function(deployer, network, accounts) {
  if (network == "development") {
    deployer.deploy(UniswapFactoryMock).then(async () => {
      await setup(web3);
    });
  }
};
