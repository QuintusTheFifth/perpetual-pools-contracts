// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

/*
@title The pool controller contract interface
*/
interface ILeveragedPool {
    struct Initialization {
        address _owner;
        address _keeper; // The address of the PoolKeeper contract
        address _oracleWrapper; // The oracle wrapper for the derivative price feed
        address _settlementEthOracle; // The oracle wrapper for the SettlementToken/ETH price feed
        address _longToken;
        address _shortToken;
        address _poolCommitter;
        string _poolName; // The pool identification name
        uint32 _frontRunningInterval; // The minimum number of seconds that must elapse before a commit is forced to wait until the next interval
        uint32 _updateInterval; // The minimum number of seconds that must elapse before a commit can be executed.
        bytes16 _fee; // The fund movement fee. This amount is extracted from the deposited asset with every update and sent to the fee address.
        uint16 _leverageAmount; // The amount of exposure to price movements for the pool
        address _feeAddress; // The address that the fund movement fee is sent to
        address _quoteToken; //  The digital asset that the pool accepts. Must have
    }

    // #### Events
    /**
     * @notice Creates a notification when the pool is setup and ready for use
     * @param longToken The address of the LONG pair token
     * @param shortToken The address of the SHORT pair token
     * @param quoteToken The address of the digital asset that the pool accepts
     * @param poolName The pool code for the pool
     */
    event PoolInitialized(address indexed longToken, address indexed shortToken, address quoteToken, string poolName);

    event PriceChange(int256 indexed startPrice, int256 indexed endPrice);

    event PriceChangeError(int256 indexed startPrice, int256 indexed endPrice);

    /**
     * @notice Represents change in fee receiver's address
     * @param oldAddress Previous address
     * @param newAddress Address after change
     */
    event FeeAddressUpdated(address indexed oldAddress, address indexed newAddress);

    /**
     * @notice Represents change in keeper's address
     * @param oldAddress Previous address
     * @param newAddress Address after change
     */
    event KeeperAddressChanged(address indexed oldAddress, address indexed newAddress);

    /**
     * @notice Represents change in governance address
     * @param oldAddress Previous address
     * @param newAddress Address after change
     */
    event GovernanceAddressChanged(address indexed oldAddress, address indexed newAddress);

    function leverageAmount() external view returns (bytes16);

    function poolCommitter() external view returns (address);

    function quoteToken() external view returns (address);

    function oracleWrapper() external view returns (address);

    function lastPriceTimestamp() external view returns (uint256);

    function poolName() external view returns (string calldata);

    function updateInterval() external view returns (uint32);

    function shortBalance() external view returns (uint256);

    function longBalance() external view returns (uint256);

    function frontRunningInterval() external view returns (uint32);

    function poolTokens() external view returns (address[2] memory);

    function settlementEthOracle() external view returns (address);

    // #### Functions
    /**
     * @notice Configures the pool on deployment. The pools are EIP 1167 clones.
     * @dev This should only be able to be run once to prevent abuse of the pool. Use of Openzeppelin Initializable or similar is recommended.
     * @param initialization The struct Initialization containing initialization data
     */
    function initialize(Initialization calldata initialization) external;

    function poolUpkeep(int256 _oldPrice, int256 _newPrice) external;

    function quoteTokenTransferFrom(
        address from,
        address to,
        uint256 amount
    ) external;

    function quoteTokenTransfer(address to, uint256 amount) external;

    function setNewPoolBalances(uint256 _longBalance, uint256 _shortBalance) external;

    function getOraclePrice() external view returns (int256);

    function intervalPassed() external view returns (bool);

    /**
     * @notice Changes the address of the keeper contract
     * @param _keeper Address of the new keeper contract
     */
    function setKeeper(address _keeper) external;

    /**
     * @dev Allows the governor to transfer governance rights to another address
     */
    function transferGovernance(address _governance) external;

    /**
     * @notice sets the address that can pull fees from this pool
     */
    function updateFeeAddress(address account) external;

    /**
     * @notice Mints new tokens
     */
    function mintTokens(
        uint256 token,
        uint256 amount,
        address burner
    ) external;

    /**
     * @notice burns an amount of pool tokens from someones account
     */
    function burnTokens(
        uint256 token,
        uint256 amount,
        address burner
    ) external;
}
