const timestamp = (block = "latest", web3) => {
  return new Promise((resolve, reject) => {
    web3.eth.getBlock(block, false, (err, {timestamp}) => {
      if (err) {
        return reject(err);
      } else {
        resolve(timestamp);
      }
    });
  });
};

// Wait for n blocks to pass
const waitForNSeconds = async function(seconds, web3Provider = web3) {
  await send("evm_increaseTime", [seconds], web3Provider);
  await send("evm_mine", [], web3Provider);
};

module.exports = {
  timestamp,
  waitForNSeconds
};
