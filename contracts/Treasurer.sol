pragma solidity ^0.5.2;

import "./yToken.sol";
import "./oracle/Oracle.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./libraries/ExponentialOperations.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

contract Treasurer is Ownable {
    using SafeMath for uint256;
    using ExponentialOperations for uint256;

    struct Repo {
        uint256 lockedCollateralAmount;
        uint256 debtAmount;
    }

    mapping(uint256 => yToken) public yTokens;
    mapping(uint256 => mapping(address => Repo)) public repos; // lockedCollateralAmount ETH and debtAmount
    mapping(address => uint256) public unlocked; // unlocked ETH
    mapping(uint256 => uint256) public settled; // settlement price of collateral
    uint256[] public issuedSeries;
    Oracle public oracle;
    uint256 public collateralRatio; // collateralization ratio
    uint256 public minCollateralRatio; // minimum collateralization ratio
    uint256 public totalSeries = 0;

    constructor(uint256 collateralRatio_, uint256 minCollateralRatio_)
        public
        Ownable()
    {
        collateralRatio = collateralRatio_;
        minCollateralRatio = minCollateralRatio_;
    }

    // --- Actions ---

    // provide address to oracle
    // oracle_ - address of the oracle contract
    function setOracle(Oracle oracle_) external onlyOwner {
        require(address(oracle) == address(0), "oracle was already set");
        oracle = oracle_;
    }

    // get oracle value
    function getSettlmentVSCollateralTokenRate()
        public
        view
        returns (uint256 r)
    {
        r = oracle.read();
    }

    // issue new yToken
    function createNewYToken(uint256 maturityTime)
        external
        returns (uint256 series)
    {
        require(maturityTime > now, "treasurer-issue-maturity-is-in-past");
        series = totalSeries;
        require(
            address(yTokens[series]) == address(0),
            "treasurer-issue-may-not-reissue-series"
        );
        yToken _token = new yToken(maturityTime);
        yTokens[series] = _token;
        issuedSeries.push(series);
        totalSeries = totalSeries + 1;
    }

    // add collateral to repo
    function topUpCollateral() external payable {
        require(
            msg.value >= 0,
            "treasurer-topUpCollateral-collateralRatio-include-deposit"
        );
        unlocked[msg.sender] = unlocked[msg.sender].add(msg.value);
    }

    // remove collateral from repo
    // amount - amount of ETH to remove from unlocked account
    // TO-DO: Update as described in https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/
    function withdrawCollateral(uint256 amount) external {
        require(
            amount >= 0,
            "treasurer-withdrawCollateral-insufficient-balance"
        );
        unlocked[msg.sender] = unlocked[msg.sender].sub(amount);
        msg.sender.transfer(amount);
    }

    // issueYToken a new yToken
    // series - yToken to mint
    // made   - amount of yToken to mint
    // paid   - amount of collateral to lock up
    function issueYToken(uint256 series, uint256 made, uint256 paid) external {
        require(series < totalSeries, "treasurer-make-unissued-series");
        // first check if sufficient capital to lock up
        require(
            unlocked[msg.sender] >= paid,
            "treasurer-issueYToken-insufficient-unlocked-to-lock"
        );

        Repo memory repo = repos[series][msg.sender];
        uint256 rate = getSettlmentVSCollateralTokenRate(); // to add rate getter!!!
        uint256 min = made.wmul(collateralRatio).wmul(rate);
        require(
            paid >= min,
            "treasurer-issueYToken-insufficient-collateral-for-those-tokens"
        );

        // lock msg.sender Collateral, add debtAmount
        unlocked[msg.sender] = unlocked[msg.sender].sub(paid);
        repo.lockedCollateralAmount = repo.lockedCollateralAmount.add(paid);
        repo.debtAmount = repo.debtAmount.add(made);
        repos[series][msg.sender] = repo;

        // mint new yTokens
        // first, ensure yToken is initialized and matures in the future
        require(
            yTokens[series].maturityTime() > now,
            "treasurer-issueYToken-invalid-or-matured-ytoken"
        );
        yTokens[series].mint(msg.sender, made);
    }

    // check that wipe leaves sufficient collateral
    // series - yToken to mint
    // credit   - amount of yToken to wipe
    // released  - amount of collateral to free
    // returns (true, 0) if sufficient collateral would remain
    // returns (false, deficiency) if sufficient collateral would not remain
    function wipeCheck(uint256 series, uint256 credit, uint256 released)
        public
        view
        returns (bool, uint256)
    {
        require(series < totalSeries, "treasurer-wipeCheck-unissued-series");
        Repo memory repo = repos[series][msg.sender];
        require(
            repo.lockedCollateralAmount >= released,
            "treasurer-wipe-release-more-than-locked"
        );
        require(
            repo.debtAmount >= credit,
            "treasurer-wipe-wipe-more-debtAmount-than-present"
        );
        // if would be undercollateralized after freeing clean, fail
        uint256 rlocked = repo.lockedCollateralAmount.sub(released);
        uint256 rdebt = repo.debtAmount.sub(credit);
        uint256 rate = getSettlmentVSCollateralTokenRate(); // to add rate getter!!!
        uint256 min = rdebt.wmul(collateralRatio).wmul(rate);
        uint256 deficiency = 0;
        if (min >= rlocked) {
            deficiency = min.sub(rlocked);
        }
        return (rlocked >= min, deficiency);
    }

    // wipe repo debtAmount with yToken
    // series - yToken to mint
    // credit   - amount of yToken to wipe
    // released  - amount of collateral to free
    function wipe(uint256 series, uint256 credit, uint256 released) external {
        require(series < totalSeries, "treasurer-wipe-unissued-series");
        // if yToken has matured, should call resolve
        require(
            now < yTokens[series].maturityTime(),
            "treasurer-wipe-yToken-has-matured"
        );

        Repo memory repo = repos[series][msg.sender];
        require(
            repo.lockedCollateralAmount >= released,
            "treasurer-wipe-release-more-than-locked"
        );
        require(
            repo.debtAmount >= credit,
            "treasurer-wipe-wipe-more-debtAmount-than-present"
        );
        // if would be undercollateralized after freeing clean, fail
        uint256 rlocked = repo.lockedCollateralAmount.sub(released);
        uint256 rdebt = repo.debtAmount.sub(credit);
        uint256 rate = getSettlmentVSCollateralTokenRate(); // to add rate getter!!!
        uint256 min = rdebt.wmul(collateralRatio).wmul(rate);
        require(
            rlocked >= min,
            "treasurer-wipe-insufficient-remaining-collateral"
        );

        //burn tokens
        require(
            yTokens[series].balanceOf(msg.sender) > credit,
            "treasurer-wipe-insufficient-token-balance"
        );
        yTokens[series].burnFrom(msg.sender, credit);

        // reduce the collateral and the debtAmount
        repo.lockedCollateralAmount = repo.lockedCollateralAmount.sub(released);
        repo.debtAmount = repo.debtAmount.sub(credit);
        repos[series][msg.sender] = repo;

        // add collateral back to the unlocked
        unlocked[msg.sender] = unlocked[msg.sender].add(released);
    }

    // liquidate a repo
    // series - yToken of debtAmount to buy
    // bum    - owner of the undercollateralized repo
    // amount - amount of yToken debtAmount to buy
    function liquidate(uint256 series, address bum, uint256 amount) external {
        require(series < totalSeries, "treasurer-liquidate-unissued-series");
        //check that repo is in danger zone
        Repo memory repo = repos[series][bum];
        uint256 rate = getSettlmentVSCollateralTokenRate(); // to add rate getter!!!
        uint256 min = repo.debtAmount.wmul(minCollateralRatio).wmul(rate);
        require(repo.lockedCollateralAmount < min, "treasurer-bite-still-safe");

        //burn tokens
        yTokens[series].burnByOwner(msg.sender, amount);

        //update repo
        uint256 bitten = amount.wmul(minCollateralRatio).wmul(rate);
        repo.lockedCollateralAmount = repo.lockedCollateralAmount.sub(bitten);
        repo.debtAmount = repo.debtAmount.sub(amount);
        repos[series][bum] = repo;
        // send bitten funds
        msg.sender.transfer(bitten);
    }

    // trigger settlement
    // series - yToken of debtAmount to settle
    function settlement(uint256 series) external {
        require(series < totalSeries, "treasurer-settlement-unissued-series");
        require(
            now > yTokens[series].maturityTime(),
            "treasurer-settlement-yToken-hasnt-matured"
        );
        require(
            settled[series] == 0,
            "treasurer-settlement-settlement-already-called"
        );
        settled[series] = getSettlmentVSCollateralTokenRate();
    }

    // redeem tokens for underlying Ether
    // series - matured yToken
    // amount    - amount of yToken to close
    function withdraw(uint256 series, uint256 amount) external {
        require(series < totalSeries, "treasurer-withdraw-unissued-series");
        require(
            now > yTokens[series].maturityTime(),
            "treasurer-withdraw-yToken-hasnt-matured"
        );
        require(
            settled[series] != 0,
            "treasurer-settlement-settlement-not-yet-called"
        );

        yTokens[series].burnByOwner(msg.sender, amount);

        uint256 rate = settled[series];
        uint256 goods = amount.wmul(rate);
        msg.sender.transfer(goods);
    }

    // series - matured yToken
    // close repo and retrieve remaining Ether
    function close(uint256 series) external {
        require(series < totalSeries, "treasurer-close-unissued-series");
        require(
            now > yTokens[series].maturityTime(),
            "treasurer-withdraw-yToken-hasnt-matured"
        );
        require(
            settled[series] != 0,
            "treasurer-settlement-settlement-not-yet-called"
        );

        Repo memory repo = repos[series][msg.sender];
        uint256 rate = settled[series]; // to add rate getter!!!
        uint256 remainder = repo.debtAmount.wmul(rate);

        require(
            repo.lockedCollateralAmount > remainder,
            "treasurer-settlement-repo-underfunded-at-settlement"
        );
        uint256 goods = repo.lockedCollateralAmount.sub(
            repo.debtAmount.wmul(rate)
        );
        repo.lockedCollateralAmount = 0;
        repo.debtAmount = 0;
        repos[series][msg.sender] = repo;

        msg.sender.transfer(goods);
    }
}
