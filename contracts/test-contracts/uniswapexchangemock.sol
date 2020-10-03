pragma solidity ^0.5.2;
// Solidity Interface

contract UniswapExchangeMock {
    function getEthToTokenInputPrice(uint256 eth_sold)
        external
        pure
        returns (uint256 tokens_bought)
    {
        return 0.98 ether + (eth_sold - eth_sold);
    }

}
