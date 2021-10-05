// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "../interfaces/IOracleWrapper.sol";
import "../interfaces/IHistoricalOracleWrapper.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SMAOracle is Ownable, IOracleWrapper {
    /// Price oracle supplying the spot price of the quote asset
    address public override oracle;

    /// Current SMA price
    int256 public price;

    /// Total allowed size of the (**statically-allocated**) array storing the dataset
    uint256 public constant capacity = 24;

    /// Array storing the dataset of previous spot prices
    int256[capacity] public observations;

    /// Number of periods to use in calculating the SMA (`k` in the SMA equation)
    uint256 public periods;

    /// Initial price to report in the base case where the oracle is unpopulated
    int256 public constant INITIAL_PRICE = 1;

    /// Whether or not `update` has been called on this instance of the contract
    /// or not
    bool private updated;

    constructor(address _spotOracle, uint256 _periods) {
        setPeriods(_periods);
        setOracle(_spotOracle);
        price = INITIAL_PRICE;
        updated = false;
    }

    /**
     * @notice Sets the number of periods to be used in performing SMA calculations
     * @param _periods Number of periods to use in SMA calculation
     * @dev `_periods` is `k` in the SMA equation
     * @dev Throws if `_periods` is less than zero
     * @dev Throws if `_periods` is less than `capacity`
     *
     */
    function setPeriods(uint256 _periods) public onlyOwner {
        /* bounds check */
        require(_periods > 0 && _periods <= capacity, "SMA: Out of bounds");
        periods = _periods;
    }

    function setOracle(address _spotOracle) public override onlyOwner {
        oracle = _spotOracle;
    }

    function getPrice() external view override onlyUpdated returns (int256) {
        return price;
    }

    /**
     * @notice Populates the observations array with historical prices from the
     *          spot oracle
     * @dev O(n) cost due to n calls (where n is `capacity`)
     * @dev Sets the `updated` flag to `true`
     * @dev Throws if `updated` flag is `true` (prior to the call)
     *
     */
    function initialise() public {
        /* guard against double-initialisations */
        require(!updated, "SMA: Already initialised");
        uint256 n = capacity;
        IHistoricalOracleWrapper spotOracle = IHistoricalOracleWrapper(oracle);

        /* linear scan over entire observations array */
        for (uint256 i = 0; i < n; i++) {
            observations[i] = spotOracle.getPrice(n - i);
        }

        updated = true;
    }

    function update(int256 _observation) public {
        /* TODO: implement `update` */
    }

    /**
     * @notice Calculates the simple moving average of the provided dataset for the specified number of periods
     * @param xs Dataset
     * @param k Number of periods to use for calculation of the SMA
     * @return Simple moving average for `k` periods
     * @dev Throws if `k` is zero (due to necessary division)
     * @dev Throws if `k` is greater than or equal to the length of `xs` (due to buffer overrun potential)
     * @dev Throws if `k` is the maximum *signed* 256-bit integer (due to necessary division)
     * @dev O(k) complexity due to linear traversal of the final `k` elements of `xs`
     * @dev Note that the signedness of the return type is due to the signedness of the elements of `xs`
     *
     */
    function SMA(int256[capacity] memory xs, uint256 k) public pure returns (int256) {
        uint256 n = xs.length;

        /* bounds check */
        require(k > 0 && k <= n && k <= uint256(type(int256).max), "SMA: Out of bounds");

        /* running total */
        int256 S = 0;

        /* linear scan over the [n - k, n] subsequence */
        for (uint256 i = n - k; i < n; i++) {
            S += xs[i];
        }

        /* cast is safe due to above bounds check */
        return S / int256(k);
    }

    /**
     * @notice Rotates `xs` to the **left** by one element and sets the last element of `xs` to `x`
     * @param xs Array to rotate
     * @param x Element to "rotate into" `xs`
     *
     */
    function leftRotateWithPad(int256[capacity] memory xs, int256 x) public pure {
        uint256 n = xs.length;

        /* linear scan over the [1, n] subsequence */
        for (uint256 i = 1; i < n; i++) {
            xs[i - 1] = xs[i];
        }

        /* rotate `x` into `xs` from the right (remember, we're **left**
         * rotating -- with padding!) */
        xs[n - 1] = x;
    }

    function fromWad(int256 wad) external view override returns (int256) {
        /* TODO: implement `fromWad` */
    }

    function getPriceAndMetadata() external view override onlyUpdated returns (int256 _price, bytes memory _data) {
        /* TODO: implement `getPriceAndMetadata` */
    }

    /**
     * @notice Checks that the oracle has been initialised with price data via a
     *          successful call to `SMAOracle.update`
     *
     */
    modifier onlyUpdated() {
        require(updated, "SMA: Uninitialised");
        _;
    }
}
