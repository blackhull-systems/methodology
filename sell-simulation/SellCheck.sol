// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SellCheck
/// @notice Buys a small amount of a token from one live pool and immediately sells all of it back, then reports
///         what each leg moved. It is never deployed: the token check places this code at an unused address with
///         an `eth_call` state override, so nothing is sent, signed or paid, and the chain is unchanged.
/// @dev Each leg runs as an external call to this contract so that a revert in the sell is captured with its
///      reason instead of discarding the buy. Taxes are measured from balance movements, not from what the
///      token claims about itself: a token can lie in a view function, it cannot lie in a transfer.
///      The SALE moves the token the way a router does: approve a spender, and the spender pulls it with
///      transferFrom. A copy of this code at the spender — this contract's own address with its lowest bit flipped — is
///      that spender. The token check places both copies at a fresh random address pair on every check, each copy
///      followed by random bytes, so a token cannot recognize the simulator by its address or by its code hash.
///      A token that lets a holder push tokens with transfer() but refuses a router's transferFrom() traps
///      every real seller, so a sale simulated with transfer() would wrongly read as sellable.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
}

interface IV2Pair {
    function getReserves() external view returns (uint256, uint256, uint256);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IAeroPool {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

interface IV3Pool {
    function token0() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256, int256);
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

contract SellCheck {
    uint8 internal constant V2 = 1;
    uint8 internal constant AERO_V2 = 2;
    uint8 internal constant V3 = 3;
    uint8 internal constant V4 = 4;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint160 internal constant MIN_SQRT = 4295128740;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    struct Leg {
        bool ok;
        uint256 sent; // what this contract gave up
        uint256 poolMoved; // what the pool released (buy) or actually received (sell)
        uint256 received; // what arrived in this contract
        uint256 gasUsed;
        bytes err;
    }

    // Context for the callback of the leg in flight. Only ever set and read inside one eth_call.
    address internal expectedCaller;
    address internal payToken;
    bool internal payByPull;

    receive() external payable {}

    /// @param kind V2, AERO_V2, V3 or V4.
    /// @param pool The pair or pool address; ignored for V4.
    /// @param quote WETH, an ERC-20 quote token, or address(0) for native ETH (V4 only).
    /// @param amountIn Quote spent on the buy.
    /// @param key The pool key, for V4 only.
    function run(uint8 kind, address pool, address token, address quote, uint256 amountIn, PoolKey calldata key)
        external
        returns (Leg memory buy, Leg memory sell)
    {
        if (quote == WETH) IWETH(WETH).deposit{value: amountIn}();
        uint256 g = gasleft();
        try this.buyLeg(kind, pool, token, quote, amountIn, key) returns (uint256 poolMoved, uint256 received) {
            buy = Leg(true, amountIn, poolMoved, received, g - gasleft(), "");
        } catch (bytes memory err) {
            buy = Leg(false, amountIn, 0, 0, g - gasleft(), err);
            return (buy, sell);
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        g = gasleft();
        try this.sellLeg(kind, pool, token, quote, balance, key) returns (uint256 poolMoved, uint256 received) {
            sell = Leg(true, balance, poolMoved, received, g - gasleft(), "");
        } catch (bytes memory err) {
            sell = Leg(false, balance, 0, 0, g - gasleft(), err);
        }
    }

    function buyLeg(uint8 kind, address pool, address token, address quote, uint256 amountIn, PoolKey calldata key)
        external
        returns (uint256 poolMoved, uint256 received)
    {
        require(msg.sender == address(this), "self only");
        uint256 before = IERC20(token).balanceOf(address(this));
        if (kind == V4) {
            poolMoved = _v4(key, quote, token, amountIn, false);
        } else if (kind == V3) {
            poolMoved = _v3(pool, quote, amountIn, false);
        } else {
            _pay(quote, pool, amountIn);
            poolMoved = _v2(kind, pool, quote, token);
        }
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    function sellLeg(uint8 kind, address pool, address token, address quote, uint256 amount, PoolKey calldata key)
        external
        returns (uint256 poolMoved, uint256 received)
    {
        require(msg.sender == address(this), "self only");
        uint256 before = _balance(quote);
        if (kind == V4) {
            poolMoved = _v4(key, token, quote, amount, true);
        } else if (kind == V3) {
            uint256 poolBefore = IERC20(token).balanceOf(pool);
            _v3(pool, token, amount, true);
            poolMoved = IERC20(token).balanceOf(pool) - poolBefore;
        } else {
            uint256 poolBefore = IERC20(token).balanceOf(pool);
            _pull(token, pool, amount);
            poolMoved = IERC20(token).balanceOf(pool) - poolBefore;
            _v2(kind, pool, token, quote);
        }
        received = _balance(quote) - before;
    }

    /// @dev Swap whatever `tokenIn` the pair holds above its reserve, which is what a fee-on-transfer token
    ///      actually delivered. Returns the amount of the other token the pair was asked to release.
    function _v2(uint8 kind, address pool, address tokenIn, address tokenOut) internal returns (uint256 out) {
        (uint256 r0, uint256 r1,) = IV2Pair(pool).getReserves();
        bool inIs0 = IV2Pair(pool).token0() == tokenIn;
        uint256 amountIn = IERC20(tokenIn).balanceOf(pool) - (inIs0 ? r0 : r1);
        if (kind == AERO_V2) {
            out = IAeroPool(pool).getAmountOut(amountIn, tokenIn);
        } else {
            (uint256 rIn, uint256 rOut) = inIs0 ? (r0, r1) : (r1, r0);
            out = (amountIn * 997 * rOut) / (rIn * 1000 + amountIn * 997);
        }
        tokenOut; // the pair knows which side it pays out
        IV2Pair(pool).swap(inIs0 ? 0 : out, inIs0 ? out : 0, address(this), "");
    }

    function _v3(address pool, address tokenIn, uint256 amountIn, bool pull) internal returns (uint256 out) {
        bool zeroForOne = IV3Pool(pool).token0() == tokenIn;
        expectedCaller = pool;
        payToken = tokenIn;
        payByPull = pull;
        (int256 a0, int256 a1) =
            IV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT : MAX_SQRT, "");
        out = uint256(-(zeroForOne ? a1 : a0));
    }

    /// @dev Uniswap v3 and Aerodrome Slipstream both call back under this name.
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        require(msg.sender == expectedCaller, "unexpected caller");
        uint256 owed = uint256(a0 > 0 ? a0 : a1);
        if (payByPull) _pull(payToken, msg.sender, owed);
        else _pay(payToken, msg.sender, owed);
    }

    function _v4(PoolKey calldata key, address tokenIn, address tokenOut, uint256 amountIn, bool settleFirst)
        internal
        returns (uint256)
    {
        bytes memory res = IPoolManager(POOL_MANAGER).unlock(abi.encode(key, tokenIn, tokenOut, amountIn, settleFirst));
        return abi.decode(res, (uint256));
    }

    /// @dev Buy: swap, pay what is owed, take the token (a transfer tax shows as received < taken).
    ///      Sell: hand the token over first and swap only what the manager actually credited, so a
    ///      fee-on-transfer token is measured rather than reverting as unsettled.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "unexpected caller");
        (PoolKey memory key, address tokenIn, address tokenOut, uint256 amountIn, bool settleFirst) =
            abi.decode(data, (PoolKey, address, address, uint256, bool));
        uint256 credited = amountIn;
        if (settleFirst) credited = _settle(tokenIn, amountIn, true);
        bool zeroForOne = key.currency0 == tokenIn;
        int256 delta = IPoolManager(POOL_MANAGER).swap(
            key, SwapParams(zeroForOne, -int256(credited), zeroForOne ? MIN_SQRT : MAX_SQRT), ""
        );
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        (int128 dIn, int128 dOut) = zeroForOne ? (d0, d1) : (d1, d0);
        if (!settleFirst) {
            _settle(tokenIn, uint256(int256(-dIn)), false);
        } else {
            require(-int256(dIn) <= int256(credited), "swap took more than credited");
        }
        uint256 out = uint256(int256(dOut));
        IPoolManager(POOL_MANAGER).take(tokenOut, address(this), out);
        return abi.encode(settleFirst ? credited : out);
    }

    function _settle(address currency, uint256 amount, bool pull) internal returns (uint256) {
        if (currency == address(0)) return IPoolManager(POOL_MANAGER).settle{value: amount}();
        IPoolManager(POOL_MANAGER).sync(currency);
        if (pull) _pull(currency, POOL_MANAGER, amount);
        else _pay(currency, POOL_MANAGER, amount);
        return IPoolManager(POOL_MANAGER).settle();
    }

    /// @dev transfer(), accepting the tokens that return nothing as well as those that return true.
    function _pay(address token, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSignature("transfer(address,uint256)", to, amount), "transfer failed");
    }

    /// @dev As a router sells: approve the spender for exactly `amount`, and the spender pulls it with transferFrom.
    function _pull(address token, address to, uint256 amount) internal {
        address spender = address(uint160(address(this)) ^ 1);
        _call(token, abi.encodeWithSignature("approve(address,uint256)", spender, amount), "approve failed");
        SellCheck(payable(spender)).pullFrom(token, address(this), to, amount);
    }

    /// @notice The spender's half of a sale: move `amount` of `token` from `from` to `to` under the allowance it was given.
    function pullFrom(address token, address from, address to, uint256 amount) external {
        _call(token, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount), "transferFrom failed");
    }

    /// @dev A call that must succeed and, if it returns data, return true; its own revert reason is passed on.
    function _call(address token, bytes memory data, string memory what) internal {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            revert(what);
        }
        require(ret.length == 0 || abi.decode(ret, (bool)), what);
    }

    function _balance(address currency) internal view returns (uint256) {
        return currency == address(0) ? address(this).balance : IERC20(currency).balanceOf(address(this));
    }
}
