pragma solidity ^0.5.2;

import "./yToken.sol";
import "./oracle/Oracle.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./libraries/ExponentialOperations.sol";

contract Treasurer {
    using SafeMath for uint256;
    using ExponentialOperations for uint256;

    struct Repo {
        uint256 locked; // Locked Collateral
        uint256 unminted; // unminted
        uint256 debt; // Debt
    }

    struct yieldT {
        address where; // contract address of yToken
        uint256 when; // maturity time of yToken
    }

    mapping(uint256 => yieldT) public yTokens;
    mapping(uint256 => mapping(address => Repo)) public repos; // locked ETH and debt
    mapping(address => uint256) public unlocked; // unlocked ETH
    mapping(uint256 => uint256) public settled; // settlement price of collateral
    uint256[] public issuedSeries;
    address public owner;
    address public oracle;
    uint256 public collateralRatio; // collateralization ratio
    uint256 public minCollateralRatio; // minimum collateralization ratio
    uint256 public totalSeries = 0;

    constructor(
        address owner_,
        uint256 collateralRatio_,
        uint256 minCollateralRatio_
    ) public {
        owner = owner_;
        collateralRatio = collateralRatio_;
        minCollateralRatio = minCollateralRatio_;
    }

    // --- Views ---

    // return unlocked collateral balance
    function balance(address usr) public view returns (uint256) {
        return unlocked[usr];
    }

    // --- Actions ---

    // provide address to oracle
    // oracle_ - address of the oracle contract
    function setOracle(address oracle_) external {
        require(msg.sender == owner);
        oracle = oracle_;
    }

    // get oracle value
    function peek() public view returns (uint256 r) {
        Oracle _oracle = Oracle(oracle);
        r = _oracle.read();
    }

    // issue new yToken
    function issue(uint256 when) external returns (uint256 series) {
        require(msg.sender == owner, "treasurer-issue-only-owner-may-issue");
        require(when > now, "treasurer-issue-maturity-is-in-past");
        series = totalSeries;
        require(
            yTokens[series].when == 0,
            "treasurer-issue-may-not-reissue-series"
        );
        yToken _token = new yToken(when);
        address _a = address(_token);
        yieldT memory yT = yieldT(_a, when);
        yTokens[series] = yT;
        issuedSeries.push(series);
        totalSeries = totalSeries + 1;
    }

    // add collateral to repo
    function join() external payable {
        require(
            msg.value >= 0,
            "treasurer-join-collateralRatio-include-deposit"
        );
        unlocked[msg.sender] = unlocked[msg.sender].add(msg.value);
    }

    // remove collateral from repo
    // amount - amount of ETH to remove from unlocked account
    // TO-DO: Update as described in https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/
    function exit(uint256 amount) external {
        require(amount >= 0, "treasurer-exit-insufficient-balance");
        unlocked[msg.sender] = unlocked[msg.sender].sub(amount);
        msg.sender.transfer(amount);
    }

    // make a new yToken
    // series - yToken to mint
    // made   - amount of yToken to mint
    // paid   - amount of collateral to lock up
    function make(uint256 series, uint256 made, uint256 paid) external {
        require(series < totalSeries, "treasurer-make-unissued-series");
        // first check if sufficient capital to lock up
        require(
            unlocked[msg.sender] >= paid,
            "treasurer-make-insufficient-unlocked-to-lock"
        );

        Repo memory repo = repos[series][msg.sender];
        uint256 rate = peek(); // to add rate getter!!!
        uint256 min = made.wmul(collateralRatio).wmul(rate);
        require(
            paid >= min,
            "treasurer-make-insufficient-collateral-for-those-tokens"
        );

        // lock msg.sender Collateral, add debt
        unlocked[msg.sender] = unlocked[msg.sender].sub(paid);
        repo.locked = repo.locked.add(paid);
        repo.debt = repo.debt.add(made);
        repos[series][msg.sender] = repo;

        // mint new yTokens
        // first, ensure yToken is initialized and matures in the future
        require(
            yTokens[series].when > now,
            "treasurer-make-invalid-or-matured-ytoken"
        );
        yToken yT = yToken(yTokens[series].where);
        address sender = msg.sender;
        yT.mint(sender, made);
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
            repo.locked >= released,
            "treasurer-wipe-release-more-than-locked"
        );
        require(
            repo.debt >= credit,
            "treasurer-wipe-wipe-more-debt-than-present"
        );
        // if would be undercollateralized after freeing clean, fail
        uint256 rlocked = repo.locked.sub(released);
        uint256 rdebt = repo.debt.sub(credit);
        uint256 rate = peek(); // to add rate getter!!!
        uint256 min = rdebt.wmul(collateralRatio).wmul(rate);
        uint256 deficiency = 0;
        if (min >= rlocked) {
            deficiency = min.sub(rlocked);
        }
        return (rlocked >= min, deficiency);
    }

    // wipe repo debt with yToken
    // series - yToken to mint
    // credit   - amount of yToken to wipe
    // released  - amount of collateral to free
    function wipe(uint256 series, uint256 credit, uint256 released) external {
        require(series < totalSeries, "treasurer-wipe-unissued-series");
        // if yToken has matured, should call resolve
        require(
            now < yTokens[series].when,
            "treasurer-wipe-yToken-has-matured"
        );

        Repo memory repo = repos[series][msg.sender];
        require(
            repo.locked >= released,
            "treasurer-wipe-release-more-than-locked"
        );
        require(
            repo.debt >= credit,
            "treasurer-wipe-wipe-more-debt-than-present"
        );
        // if would be undercollateralized after freeing clean, fail
        uint256 rlocked = repo.locked.sub(released);
        uint256 rdebt = repo.debt.sub(credit);
        uint256 rate = peek(); // to add rate getter!!!
        uint256 min = rdebt.wmul(collateralRatio).wmul(rate);
        require(
            rlocked >= min,
            "treasurer-wipe-insufficient-remaining-collateral"
        );

        //burn tokens
        yToken yT = yToken(yTokens[series].where);
        require(
            yT.balanceOf(msg.sender) > credit,
            "treasurer-wipe-insufficient-token-balance"
        );
        yT.burnFrom(msg.sender, credit);

        // reduce the collateral and the debt
        repo.locked = repo.locked.sub(released);
        repo.debt = repo.debt.sub(credit);
        repos[series][msg.sender] = repo;

        // add collateral back to the unlocked
        unlocked[msg.sender] = unlocked[msg.sender].add(released);
    }

    // liquidate a repo
    // series - yToken of debt to buy
    // bum    - owner of the undercollateralized repo
    // amount - amount of yToken debt to buy
    function liquidate(uint256 series, address bum, uint256 amount) external {
        require(series < totalSeries, "treasurer-liquidate-unissued-series");
        //check that repo is in danger zone
        Repo memory repo = repos[series][bum];
        uint256 rate = peek(); // to add rate getter!!!
        uint256 min = repo.debt.wmul(minCollateralRatio).wmul(rate);
        require(repo.locked < min, "treasurer-bite-still-safe");

        //burn tokens
        yToken yT = yToken(yTokens[series].where);
        yT.burnByOwner(msg.sender, amount);

        //update repo
        uint256 bitten = amount.wmul(minCollateralRatio).wmul(rate);
        repo.locked = repo.locked.sub(bitten);
        repo.debt = repo.debt.sub(amount);
        repos[series][bum] = repo;
        // send bitten funds
        msg.sender.transfer(bitten);
    }

    // trigger settlement
    // series - yToken of debt to settle
    function settlement(uint256 series) external {
        require(series < totalSeries, "treasurer-settlement-unissued-series");
        require(
            now > yTokens[series].when,
            "treasurer-settlement-yToken-hasnt-matured"
        );
        require(
            settled[series] == 0,
            "treasurer-settlement-settlement-already-called"
        );
        settled[series] = peek();
    }

    // redeem tokens for underlying Ether
    // series - matured yToken
    // amount    - amount of yToken to close
    function withdraw(uint256 series, uint256 amount) external {
        require(series < totalSeries, "treasurer-withdraw-unissued-series");
        require(
            now > yTokens[series].when,
            "treasurer-withdraw-yToken-hasnt-matured"
        );
        require(
            settled[series] != 0,
            "treasurer-settlement-settlement-not-yet-called"
        );

        yToken yT = yToken(yTokens[series].where);
        yT.burnByOwner(msg.sender, amount);

        uint256 rate = settled[series];
        uint256 goods = amount.wmul(rate);
        msg.sender.transfer(goods);
    }

    // series - matured yToken
    // close repo and retrieve remaining Ether
    function close(uint256 series) external {
        require(series < totalSeries, "treasurer-close-unissued-series");
        require(
            now > yTokens[series].when,
            "treasurer-withdraw-yToken-hasnt-matured"
        );
        require(
            settled[series] != 0,
            "treasurer-settlement-settlement-not-yet-called"
        );

        Repo memory repo = repos[series][msg.sender];
        uint256 rate = settled[series]; // to add rate getter!!!
        uint256 remainder = repo.debt.wmul(rate);

        require(
            repo.locked > remainder,
            "treasurer-settlement-repo-underfunded-at-settlement"
        );
        uint256 goods = repo.locked.sub(repo.debt.wmul(rate));
        repo.locked = 0;
        repo.debt = 0;
        repos[series][msg.sender] = repo;

        msg.sender.transfer(goods);
    }
}
