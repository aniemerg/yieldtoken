const Treasurer = artifacts.require("Treasurer");
const Token = artifacts.require("yToken");
const MockContract = artifacts.require("./MockContract");
const ERC20Mintable = artifacts.require("./ERC20Mintable");

module.exports = async function(deployer, network, accounts) {
  if (network == "development") {
    //Token stands in for Dai
    await deployer.deploy(ERC20Mintable);
    collateralToken = await ERC20Mintable.deployed();
    await deployer.deploy(
      Treasurer,
      collateralToken.address,
      web3.utils.toWei("1.5"),
      web3.utils.toWei("1.05")
    );
  }
};
