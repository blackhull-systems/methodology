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
    function allowance(address owner, address spender) external view returns (uint256);
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
    function fee() external view returns (uint24);
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

/// What a real user's sale goes through on Uniswap: Permit2 lets the Universal Router pull the token.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// = IV4Router.ExactInputSingleParams (Universal Router on Base, verified source)
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
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
    uint8 internal constant CL = 5; // Aerodrome Slipstream: a v3-style pool, its own router

    /// Uniswap's Universal Router and Permit2 on Base (both verified on Sourcify, 2026-11-05). The SALE goes through
    /// them on Uniswap pools, exactly as a user's sale does: a hook sees the router as the swapper, and a token sees
    /// Permit2 pull from the holder. A sale made any other way could pass where every real sale fails.
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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

    /// @param kind V2, AERO_V2, V3, V4 or CL.
    /// @param pool The pair or pool address; ignored for V4.
    /// @param quote WETH, an ERC-20 quote token, or address(0) for native ETH (V4 only).
    /// @param amountIn Quote spent on the buy.
    /// @param key The pool key, for V4 only.
    /// @return buy The buy, straight from the pool.
    /// @return sell The sale the way a user makes it: through the Universal Router on a Uniswap pool (V2, V3, V4), straight
    ///         to the pool on Aerodrome's (AERO_V2, CL).
    /// @return direct Run only when a router sale failed: the same sale straight to the pool. If it goes through, the
    ///         token or the pool's hook lets a direct trade sell while refusing the router every real seller uses.
    function run(uint8 kind, address pool, address token, address quote, uint256 amountIn, PoolKey calldata key)
        external
        returns (Leg memory buy, Leg memory sell, Leg memory direct)
    {
        if (quote == WETH) IWETH(WETH).deposit{value: amountIn}();
        uint256 g = gasleft();
        try this.buyLeg(kind, pool, token, quote, amountIn, key) returns (uint256 poolMoved, uint256 received) {
            buy = Leg(true, amountIn, poolMoved, received, g - gasleft(), "");
        } catch (bytes memory err) {
            buy = Leg(false, amountIn, 0, 0, g - gasleft(), err);
            return (buy, sell, direct);
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        bool routed = kind == V2 || kind == V3 || kind == V4;
        g = gasleft();
        if (routed) {
            try this.routerSellLeg(kind, pool, token, quote, balance, key) returns (uint256 poolMoved, uint256 received) {
                sell = Leg(true, balance, poolMoved, received, g - gasleft(), "");
                return (buy, sell, direct);
            } catch (bytes memory err) {
                sell = Leg(false, balance, 0, 0, g - gasleft(), err);
            }
            g = gasleft();
        }
        // a failed call left the balance where it was, so the direct sale sells the same tokens
        try this.sellLeg(kind, pool, token, quote, balance, key) returns (uint256 poolMoved, uint256 received) {
            Leg memory leg = Leg(true, balance, poolMoved, received, g - gasleft(), "");
            if (routed) direct = leg;
            else sell = leg;
        } catch (bytes memory err) {
            Leg memory leg = Leg(false, balance, 0, 0, g - gasleft(), err);
            if (routed) direct = leg;
            else sell = leg;
        }
    }

    /// @dev A user's sale on a Uniswap pool: approve Permit2, let Permit2 allow the Universal Router exactly `amount`,
    ///      and execute one swap — V2_SWAP_EXACT_IN (0x08), V3_SWAP_EXACT_IN (0x00) or V4_SWAP (0x10: SWAP_EXACT_IN_SINGLE,
    ///      SETTLE_ALL, TAKE_ALL), the router's own command and action codes. `poolMoved` is what the pool (or, on v4,
    ///      the PoolManager) actually received of the token: a transfer tax shows as less than `amount`.
    function routerSellLeg(uint8 kind, address pool, address token, address quote, uint256 amount, PoolKey calldata key)
        external
        returns (uint256 poolMoved, uint256 received)
    {
        require(msg.sender == address(this), "self only");
        // approve Permit2 only when its allowance is short, as a wallet does. MEASURED 2026-11-05: Doppler's tokens fix
        // Permit2's allowance at infinity and REFUSE an approve for it (Permit2AllowanceIsFixedAtInfinity), so an
        // unconditional approve read a sellable token as blocked.
        if (IERC20(token).allowance(address(this), PERMIT2) < amount) {
            _call(token, abi.encodeWithSignature("approve(address,uint256)", PERMIT2, amount), "approve failed");
        }
        IPermit2(PERMIT2).approve(token, UNIVERSAL_ROUTER, uint160(amount), uint48(block.timestamp + 3600));
        address sink = kind == V4 ? POOL_MANAGER : pool;
        uint256 sinkBefore = IERC20(token).balanceOf(sink);
        uint256 before = _balance(quote);
        bytes memory commands;
        bytes[] memory inputs = new bytes[](1);
        if (kind == V2) {
            address[] memory path = new address[](2);
            path[0] = token;
            path[1] = quote;
            commands = hex"08";
            inputs[0] = abi.encode(address(this), amount, uint256(0), path, true);
        } else if (kind == V3) {
            commands = hex"00";
            inputs[0] = abi.encode(address(this), amount, uint256(0), abi.encodePacked(token, IV3Pool(pool).fee(), quote), true);
        } else {
            PoolKey memory k = key;
            bytes[] memory params = new bytes[](3);
            params[0] = abi.encode(ExactInputSingleParams(k, k.currency0 == token, uint128(amount), 0, ""));
            params[1] = abi.encode(token, amount); // SETTLE_ALL: the currency paid in, at most this much
            params[2] = abi.encode(quote, uint256(0)); // TAKE_ALL: the currency taken out
            commands = hex"10";
            inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        }
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 600);
        poolMoved = IERC20(token).balanceOf(sink) - sinkBefore;
        received = _balance(quote) - before;
    }

    function buyLeg(uint8 kind, address pool, address token, address quote, uint256 amountIn, PoolKey calldata key)
        external
        returns (uint256 poolMoved, uint256 received)
    {
        require(msg.sender == address(this), "self only");
        uint256 before = IERC20(token).balanceOf(address(this));
        if (kind == V4) {
            poolMoved = _v4(key, quote, token, amountIn, false);
        } else if (kind == V3 || kind == CL) {
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
        } else if (kind == V3 || kind == CL) {
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
