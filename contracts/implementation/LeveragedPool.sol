// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../interfaces/ILeveragedPool.sol";
import "./PoolToken.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../vendors/SafeMath_40.sol";
import "../vendors/SafeMath_112.sol";
import "../vendors/SafeMath_128.sol";

import "./PoolSwapLibrary.sol";
import "../interfaces/IOracleWrapper.sol";

/*
@title The pool controller contract
*/
contract LeveragedPool is ILeveragedPool, Initializable {
    using SafeMath_40 for uint40;
    using SafeMath_112 for uint112;
    using SafeMath_128 for uint128;

    // #### Globals

    // Each balance is the amount of quote tokens in the pair
    uint112 public shortBalance;
    uint112 public longBalance;
    uint32 public frontRunningInterval;
    uint32 public override updateInterval;

    bytes16 public fee;
    bytes16 public leverageAmount;

    // Index 0 is the LONG token, index 1 is the SHORT token
    address[2] public tokens;

    address public owner;
    address public keeper;
    address public feeAddress;
    address public quoteToken;
    address public keeperOracle;
    uint40 public lastPriceTimestamp;

    uint128 public commitIDCounter;
    mapping(uint128 => Commit) public commits;
    mapping(CommitType => uint112) public shadowPools;
    string public poolCode;
    address public override oracleWrapper;

    // #### Functions

    function initialize(ILeveragedPool.Initialization calldata initialization) external override initializer {
        require(initialization._feeAddress != address(0), "Fee address cannot be 0 address");
        require(initialization._quoteToken != address(0), "Quote token cannot be 0 address");
        require(initialization._oracleWrapper != address(0), "Oracle wrapper cannot be 0 address");
        transferOwnershipInitializer(initialization._owner);

        // Setup variables
        oracleWrapper = _oracleWrapper;
        quoteToken = _quoteToken;
        keeperOracle = _keeperOracle;
        frontRunningInterval = _frontRunningInterval;
        updateInterval = _updateInterval;
        fee = _fee;
        leverageAmount = PoolSwapLibrary.convertUIntToDecimal(_leverageAmount);
        feeAddress = _feeAddress;
        keeper = initialization._keeper;
        lastPriceTimestamp = uint40(block.timestamp);
        poolCode = initialization._poolCode;
        tokens[0] = initialization._longToken;
        tokens[1] = initialization._shortToken;
        emit PoolInitialized(tokens[0], tokens[1], initialization._quoteToken, initialization._poolCode);
    }

    function commit(CommitType commitType, uint112 amount) external override {
        require(amount > 0, "Amount must not be zero");
        commitIDCounter = commitIDCounter.add(1);

        // create commitment
        commits[commitIDCounter] = Commit({
            commitType: commitType,
            amount: amount,
            owner: msg.sender,
            created: uint40(block.timestamp)
        });
        shadowPools[commitType] = shadowPools[commitType].add(amount);

        emit CreateCommit(commitIDCounter, amount, commitType);

        // pull in tokens
        if (commitType == CommitType.LongMint || commitType == CommitType.ShortMint) {
            // minting: pull in the quote token from the commiter
            require(IERC20(quoteToken).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        } else if (commitType == CommitType.LongBurn) {
            // long burning: pull in long pool tokens from commiter
            require(PoolToken(tokens[0]).burn(amount, msg.sender), "Transfer failed");
        } else if (commitType == CommitType.ShortBurn) {
            // short burning: pull in short pool tokens from commiter
            require(PoolToken(tokens[1]).burn(amount, msg.sender), "Transfer failed");
        }
    }

    function uncommit(uint128 _commitID) external override {
        Commit memory _commit = commits[_commitID];
        require(msg.sender == _commit.owner, "Unauthorized");
        require(_commit.owner != address(0), "Invalid commit");

        // reduce pool commitment amount
        shadowPools[_commit.commitType] = shadowPools[_commit.commitType].sub(_commit.amount);
        emit RemoveCommit(_commitID, _commit.amount, _commit.commitType);
        delete commits[_commitID];

        // release tokens
        if (_commit.commitType == CommitType.LongMint || _commit.commitType == CommitType.ShortMint) {
            // minting: return quote tokens to the commit owner
            require(IERC20(quoteToken).transfer(msg.sender, _commit.amount), "Transfer failed");
        } else if (_commit.commitType == CommitType.LongBurn) {
            // long burning: return long pool tokens to commit owner
            require(PoolToken(tokens[0]).mint(_commit.amount, msg.sender), "Transfer failed");
        } else if (_commit.commitType == CommitType.ShortBurn) {
            // short burning: return short pool tokens to the commit owner
            require(PoolToken(tokens[1]).mint(_commit.amount, msg.sender), "Transfer failed");
        }
    }

    function executeCommitment(uint128[] calldata _commitIDs) external override {
        Commit memory _commit;
        for (uint128 i = 0; i < _commitIDs.length; i++) {
            _commit = commits[_commitIDs[i]];
            delete commits[_commitIDs[i]];
            emit ExecuteCommit(_commitIDs[i]);
            _executeCommitment(_commit);
        }
    }

    /**
     * @notice Executes a single commitment.
     * @param _commit The commit to execute
     */
    function _executeCommitment(Commit memory _commit) internal {
        require(_commit.owner != address(0), "Invalid commit");
        require(lastPriceTimestamp.sub(_commit.created) > frontRunningInterval, "Commit too new");
        shadowPools[_commit.commitType] = shadowPools[_commit.commitType].sub(_commit.amount);
        if (_commit.commitType == CommitType.LongMint) {
            longBalance = longBalance.add(_commit.amount);
            _mintTokens(
                tokens[0],
                _commit.amount, // amount of quote tokens commited to enter
                longBalance.sub(_commit.amount), // total quote tokens in the long pull, excluding this mint
                shadowPools[CommitType.LongBurn], // total pool tokens commited to be burned
                _commit.owner
            );
        } else if (_commit.commitType == CommitType.LongBurn) {
            uint112 amountOut = PoolSwapLibrary.getAmountOut(
                PoolSwapLibrary.getRatio(
                    longBalance,
                    uint112(
                        uint112(PoolToken(tokens[0]).totalSupply()).add(shadowPools[CommitType.LongBurn]).add(
                            _commit.amount
                        )
                    )
                ),
                _commit.amount
            );
            longBalance = longBalance.sub(amountOut);
            require(IERC20(quoteToken).transfer(_commit.owner, amountOut), "Transfer failed");
        } else if (_commit.commitType == CommitType.ShortMint) {
            shortBalance = shortBalance.add(_commit.amount);
            _mintTokens(
                tokens[1],
                _commit.amount,
                shortBalance.sub(_commit.amount),
                shadowPools[CommitType.ShortBurn],
                _commit.owner
            );
        } else if (_commit.commitType == CommitType.ShortBurn) {
            uint112 amountOut = PoolSwapLibrary.getAmountOut(
                PoolSwapLibrary.getRatio(
                    shortBalance,
                    uint112(PoolToken(tokens[1]).totalSupply()).add(shadowPools[CommitType.ShortBurn]).add(
                        _commit.amount
                    )
                ),
                _commit.amount
            );

            shortBalance = shortBalance.sub(amountOut);
            require(IERC20(quoteToken).transfer(_commit.owner, amountOut), "Transfer failed");
        }
    }

    /**
     * @return The price of the pool's feed oracle
     */
    function getOraclePrice() public view override returns (int256) {
        return IOracleWrapper(oracleWrapper).getPrice();
    }

    /**
     * @notice Mints new tokens
     * @param token The token to mint
     * @param amountIn The amount the user has committed to minting
     * @param balance The balance of pair at the start of the execution
     * @param inverseShadowbalance The amount of tokens burned from total supply
     * @param tokenOwner The address to send the tokens to
     */
    function _mintTokens(
        address token,
        uint112 amountIn,
        uint112 balance,
        uint112 inverseShadowbalance,
        address tokenOwner
    ) internal {
        require(
            PoolToken(token).mint(
                // amount out = ratio * amount in
                PoolSwapLibrary.getAmountOut(
                    // ratio = (totalSupply + inverseShadowBalance) / balance
                    PoolSwapLibrary.getRatio(
                        uint112(PoolToken(token).totalSupply()).add(inverseShadowbalance),
                        balance
                    ),
                    amountIn
                ),
                tokenOwner
            ),
            "Mint failed"
        );
    }

    /**
     * @notice Processes the effect of a price change. This involves transferring funds from the losing pool to the other.
     * @dev This function should be called by the Pool Keeper.
     * @dev This function should be secured with some form of access control
     * @param oldPrice The previously executed price
     * @param newPrice The price for the latest interval.
     */
    function executePriceChange(int256 oldPrice, int256 newPrice) external override onlyKeeper {
        require(intervalPassed(), "Update interval hasn't passed");

        // Calculate fees from long and short sides
        uint112 longFeeAmount = uint112(
            PoolSwapLibrary.convertDecimalToUInt(PoolSwapLibrary.multiplyDecimalByUInt(fee, longBalance))
        );
        uint112 shortFeeAmount = uint112(
            PoolSwapLibrary.convertDecimalToUInt(PoolSwapLibrary.multiplyDecimalByUInt(fee, shortBalance))
        );
        uint112 totalFeeAmount = 0;
        if (shortBalance >= shortFeeAmount) {
            shortBalance = shortBalance.sub(shortFeeAmount);
            totalFeeAmount = totalFeeAmount.add(shortFeeAmount);
        }
        if (longBalance >= longFeeAmount) {
            longBalance = longBalance.sub(longFeeAmount);
            totalFeeAmount = totalFeeAmount.add(longFeeAmount);
        }

        // Use the ratio to determine if the price increased or decreased and therefore which direction
        // the funds should be transferred towards.
        bytes16 ratio = PoolSwapLibrary.divInt(newPrice, oldPrice);
        int8 direction = PoolSwapLibrary.compareDecimals(ratio, PoolSwapLibrary.one);
        // Take into account the leverage
        bytes16 lossMultiplier = PoolSwapLibrary.getLossMultiplier(ratio, direction, leverageAmount);

        if (direction >= 0 && shortBalance > 0) {
            // Move funds from short to long pair
            uint112 lossAmount = uint112(PoolSwapLibrary.getLossAmount(lossMultiplier, shortBalance));
            shortBalance = shortBalance.sub(lossAmount);
            longBalance = longBalance.add(lossAmount);
            emit PriceChange(oldPrice, newPrice, lossAmount);
        } else if (direction < 0 && longBalance > 0) {
            // Move funds from long to short pair
            uint112 lossAmount = uint112(PoolSwapLibrary.getLossAmount(lossMultiplier, longBalance));
            shortBalance = shortBalance.add(lossAmount);
            longBalance = longBalance.sub(lossAmount);
            emit PriceChange(oldPrice, newPrice, lossAmount);
        }
        lastPriceTimestamp = uint40(block.timestamp);
        require(IERC20(quoteToken).transfer(feeAddress, totalFeeAmount), "Fee transfer failed");
    }

    /**
     * @return true if the price was last updated more than updateInterval seconds ago
     */
    function intervalPassed() public view override returns (bool) {
        return block.timestamp >= lastPriceTimestamp.add(updateInterval);
    }

    function updateFeeAddress(address account) external override onlyOwner {
        require(account != address(0), "Invalid address");
        feeAddress = account;
    }

    function tipKeeper(address keeper, uint256 amount) external override onlyUpdater {
        require(IERC20(quoteToken).transfer(keeper, amount), "Tip failed");
    }

    function setKeeper(address _keeper) external override onlyOwner {
        keeper = _keeper;
    }

    function transferOwnershipInitializer(address _owner) internal initializer {
        owner = _owner;
    }

    function transferOwnership(address _owner) external override onlyOwner {
        owner = _owner;
    }

    // #### Modifiers
    modifier onlyKeeper() {
        require(msg.sender == keeper, "msg.sender not keeper");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "msg.sender not owner");
        _;
    }
}
